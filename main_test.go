package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func TestDownloadCache(t *testing.T) {
	var originCalls atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		originCalls.Add(1)
		if request.Header.Get("X-Gizlet-Skip-Cache") != "" {
			t.Error("internal cache header forwarded to origin")
		}
		writer.Header().Set("Cache-Control", "public, max-age=3600, immutable")
		writer.Header().Set("Vary", "Accept-Encoding")
		writer.Header().Set("X-Checksum-Sha256", "fixture-checksum")
		writer.Header().Set("Etag", `"fixture-etag"`)
		if request.URL.Path == "/private" {
			writer.Header().Set("Cache-Control", "no-store")
		}
		if request.Header.Get("Range") != "" {
			writer.Header().Set("Content-Range", "bytes 0-2/7")
			writer.WriteHeader(http.StatusPartialContent)
			fmt.Fprint(writer, "pay")
			return
		}
		fmt.Fprint(writer, "payload")
	}))
	defer origin.Close()

	var lock sync.Mutex
	objects := map[string][2]string{}
	uploaded := make(chan string, 4)
	store := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		lock.Lock()
		defer lock.Unlock()
		switch request.Method {
		case http.MethodPut:
			body, err := io.ReadAll(request.Body)
			if err != nil {
				t.Error(err)
				writer.WriteHeader(http.StatusBadRequest)
				return
			}
			objects[request.URL.Path] = [2]string{request.Header.Get("X-Amz-Meta-Headers"), string(body)}
			uploaded <- request.URL.Path
		case http.MethodGet:
			object, ok := objects[request.URL.Path]
			if !ok {
				writer.WriteHeader(http.StatusNotFound)
				return
			}
			writer.Header().Set("X-Amz-Meta-Headers", object[0])
			writer.Header().Set("Last-Modified", time.Now().UTC().Format(http.TimeFormat))
			fmt.Fprint(writer, object[1])
		default:
			t.Error("unexpected S3 method", request.Method)
		}
	}))
	defer store.Close()
	client := s3.New(s3.Options{
		Region: "us-east-1", BaseEndpoint: aws.String(store.URL), UsePathStyle: true,
		Credentials:                credentials.NewStaticCredentialsProvider("test", "test", ""),
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired,
	})
	originURL, err := url.Parse(origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	cache := newDownloadCache(client, "test-bucket", "test-prefix", originURL, t.TempDir())
	request := func(path, skip, byteRange string) *httptest.ResponseRecorder {
		t.Helper()
		input := httptest.NewRequest(http.MethodGet, path, nil)
		input.Header.Set("X-Gizlet-Skip-Cache", skip)
		input.Header.Set("Range", byteRange)
		result := httptest.NewRecorder()
		cache.ServeHTTP(result, input)
		return result
	}

	const path = "/package?sha256=fixture"
	if got := request(path, "0", ""); got.Code != http.StatusOK || got.Body.String() != "payload" {
		t.Fatal("origin download did not pass through")
	}
	select {
	case key := <-uploaded:
		if !strings.HasPrefix(key, "/test-bucket/test-prefix/v1/") {
			t.Fatal("unexpected S3 path", key)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("origin response did not populate S3")
	}
	got := request(path, "0", "")
	if got.Code != http.StatusOK || got.Body.String() != "payload" || originCalls.Load() != 1 ||
		got.Header().Get("X-Checksum-Sha256") != "fixture-checksum" || got.Header().Get("Etag") != `"fixture-etag"` {
		t.Fatal("S3 cache hit did not preserve data and headers")
	}
	if got := request(path, "1", ""); got.Code != http.StatusOK || originCalls.Load() != 2 {
		t.Fatal("bypassed request did not reach origin")
	}
	if got := request(path, "0", "bytes=0-2"); got.Code != http.StatusPartialContent || got.Body.String() != "pay" {
		t.Fatal("Range request did not reach origin")
	}
	if got := request("/private", "0", ""); got.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("no-store response did not pass through")
	}
	select {
	case key := <-uploaded:
		t.Fatal("unexpected S3 upload", key)
	default:
	}
	store.Close()
	if got := request(path, "0", ""); got.Code != http.StatusOK || got.Body.String() != "payload" {
		t.Fatal("origin fallback after S3 outage failed")
	}
}
