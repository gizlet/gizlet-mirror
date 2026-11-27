package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const maxUpload = 5_000_000_000

var storedHeaders = []string{
	"Accept-Ranges", "Access-Control-Allow-Origin", "Cache-Control",
	"Content-Disposition", "Content-Type", "Etag", "Last-Modified",
	"X-Checksum-Sha256", "X-Content-Type-Options",
}

type objectStore interface {
	GetObject(context.Context, *s3.GetObjectInput, ...func(*s3.Options)) (*s3.GetObjectOutput, error)
	PutObject(context.Context, *s3.PutObjectInput, ...func(*s3.Options)) (*s3.PutObjectOutput, error)
}

type cacheKey struct{}

type downloadCache struct {
	store   objectStore
	bucket  string
	prefix  string
	origin  *url.URL
	proxy   *httputil.ReverseProxy
	spool   string
	uploads chan struct{}
}

func newDownloadCache(store objectStore, bucket, prefix string, origin *url.URL, spool string) *downloadCache {
	cache := &downloadCache{store: store, bucket: bucket, prefix: prefix, origin: origin, spool: spool, uploads: make(chan struct{}, 1)}
	cache.proxy = &httputil.ReverseProxy{
		Rewrite: func(request *httputil.ProxyRequest) {
			request.SetURL(origin)
			request.Out.URL.RawQuery = request.In.URL.RawQuery
			request.Out.Header.Del("X-Gizlet-Skip-Cache")
			request.Out.Header.Set("Accept-Encoding", "identity")
			for _, header := range []string{"X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto"} {
				request.Out.Header[header] = request.In.Header.Values(header)
			}
		},
		ModifyResponse: cache.capture,
	}
	return cache
}

func (cache *downloadCache) key(request *http.Request) string {
	return fmt.Sprintf("%s/v1/%x", cache.prefix, sha256.Sum256([]byte(cache.origin.Host+request.URL.RequestURI())))
}

func canCache(request *http.Request) bool {
	if request.Method != http.MethodGet || request.Header.Get("X-Gizlet-Skip-Cache") != "0" {
		return false
	}
	for _, header := range []string{"Range", "If-Range", "If-Match", "If-None-Match", "If-Modified-Since", "If-Unmodified-Since"} {
		if request.Header.Get(header) != "" {
			return false
		}
	}
	return true
}

func lifetime(headers http.Header) time.Duration {
	var public, immutable bool
	var seconds int64
	for _, value := range headers.Values("Cache-Control") {
		for _, directive := range strings.Split(value, ",") {
			name, argument, _ := strings.Cut(strings.TrimSpace(strings.ToLower(directive)), "=")
			switch name {
			case "private", "no-store", "no-cache":
				return 0
			case "public":
				public = true
			case "immutable":
				immutable = true
			case "max-age":
				seconds, _ = strconv.ParseInt(argument, 10, 64)
			}
		}
	}
	if !public || !immutable || seconds <= 0 {
		return 0
	}
	return time.Duration(min(seconds, 31_536_000)) * time.Second
}

func (cache *downloadCache) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if canCache(request) {
		key := cache.key(request)
		if cache.serveCached(writer, request, key) {
			return
		}
		request = request.WithContext(context.WithValue(request.Context(), cacheKey{}, key))
	}
	cache.proxy.ServeHTTP(writer, request)
}

func (cache *downloadCache) serveCached(writer http.ResponseWriter, request *http.Request, key string) bool {
	ctx, cancel := context.WithCancel(request.Context())
	defer cancel()
	timer := time.AfterFunc(3*time.Second, cancel)
	object, err := cache.store.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(cache.bucket), Key: aws.String(key),
	})
	timer.Stop()
	if err != nil {
		return false
	}
	defer object.Body.Close()
	raw, err := base64.RawStdEncoding.DecodeString(object.Metadata["headers"])
	if err != nil || object.LastModified == nil || object.ContentLength == nil {
		return false
	}
	headers := make(http.Header)
	if err := json.Unmarshal(raw, &headers); err != nil {
		return false
	}
	ttl := lifetime(headers)
	age := max(time.Since(*object.LastModified), 0)
	if ttl <= age {
		return false
	}
	for _, header := range storedHeaders {
		for _, value := range headers.Values(header) {
			writer.Header().Add(header, value)
		}
	}
	writer.Header().Set("Cache-Control", fmt.Sprintf("public, max-age=%d, immutable", (ttl-age)/time.Second))
	writer.Header().Set("Content-Length", strconv.FormatInt(*object.ContentLength, 10))
	if _, err := io.Copy(writer, object.Body); err != nil {
		panic(http.ErrAbortHandler)
	}
	return true
}

func (cache *downloadCache) capture(response *http.Response) error {
	key, _ := response.Request.Context().Value(cacheKey{}).(string)
	if key == "" || response.StatusCode != http.StatusOK ||
		lifetime(response.Header) == 0 || response.ContentLength <= 0 || response.ContentLength > maxUpload ||
		len(response.Header.Values("Set-Cookie")) != 0 ||
		response.Header.Get("Content-Encoding") != "" {
		return nil
	}
	for _, value := range response.Header.Values("Vary") {
		for _, header := range strings.Split(value, ",") {
			if !strings.EqualFold(strings.TrimSpace(header), "Accept-Encoding") {
				return nil
			}
		}
	}
	headers := make(http.Header)
	for _, header := range storedHeaders {
		if values := response.Header.Values(header); len(values) != 0 {
			headers[http.CanonicalHeaderKey(header)] = values
		}
	}
	raw, err := json.Marshal(headers)
	if err != nil || len(raw) > 1400 {
		return nil
	}
	select {
	case cache.uploads <- struct{}{}:
	default:
		return nil
	}
	file, err := os.CreateTemp(cache.spool, "download-*")
	if err != nil {
		<-cache.uploads
		log.Printf("S3 cache spool: %v", err)
		return nil
	}
	if err := os.Remove(file.Name()); err != nil {
		file.Close()
		<-cache.uploads
		log.Printf("S3 cache spool: %v", err)
		return nil
	}
	response.Body = &capturedBody{
		ReadCloser: response.Body, file: file, remaining: response.ContentLength,
		upload: func() {
			defer func() { <-cache.uploads }()
			defer file.Close()
			if _, err := file.Seek(0, io.SeekStart); err != nil {
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
			defer cancel()
			_, err := cache.store.PutObject(ctx, &s3.PutObjectInput{
				Bucket: aws.String(cache.bucket), Key: aws.String(key),
				Body: file, ContentLength: aws.Int64(response.ContentLength),
				Metadata: map[string]string{"headers": base64.RawStdEncoding.EncodeToString(raw)},
			})
			if err != nil {
				log.Printf("S3 cache upload: %v", err)
			}
		},
		release: func() { <-cache.uploads },
	}
	return nil
}

type capturedBody struct {
	io.ReadCloser
	file      *os.File
	remaining int64
	upload    func()
	release   func()
}

func (body *capturedBody) Read(buffer []byte) (int, error) {
	count, err := body.ReadCloser.Read(buffer)
	if body.file != nil {
		written, writeErr := body.file.Write(buffer[:count])
		body.remaining -= int64(written)
		switch {
		case writeErr != nil || body.remaining < 0 || (err != nil && err != io.EOF):
			body.discard()
		case err == io.EOF && body.remaining == 0:
			body.file = nil
			go body.upload()
		}
	}
	return count, err
}

func (body *capturedBody) discard() {
	if body.file != nil {
		body.file.Close()
		body.file = nil
		body.release()
	}
}

func (body *capturedBody) Close() error {
	body.discard()
	return body.ReadCloser.Close()
}

func main() {
	settings, err := config.LoadDefaultConfig(context.Background(),
		config.WithDefaultRegion("us-east-1"),
		config.WithRequestChecksumCalculation(aws.RequestChecksumCalculationWhenRequired),
	)
	if err != nil {
		log.Fatal(err)
	}
	endpoint := os.Getenv("S3_ENDPOINT")
	store := s3.NewFromConfig(settings, func(options *s3.Options) {
		if endpoint != "" {
			options.BaseEndpoint = aws.String(endpoint)
			options.UsePathStyle = true
		}
	})
	originDomain := os.Getenv("ORIGIN_DOMAIN")
	if originDomain == "" {
		originDomain = "gizlet.io"
	}
	originHost := originDomain
	if originPort := os.Getenv("ORIGIN_HTTPS_PORT"); originPort != "" && originPort != "443" {
		originHost = net.JoinHostPort(originHost, originPort)
	}
	prefix := strings.Trim(os.Getenv("S3_PREFIX"), "/")
	if prefix == "" {
		prefix = "gizlet-mirror"
	}
	cache := newDownloadCache(store, os.Getenv("S3_BUCKET"), prefix,
		&url.URL{Scheme: "https", Host: originHost}, "/cache/s3-upload")
	server := &http.Server{Addr: "127.0.0.1:8081", Handler: cache, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(server.ListenAndServe())
}
