// Copyright 2026 The frp Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package limit

import (
	"bytes"
	"context"
	"io"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"golang.org/x/time/rate"
)

func TestNewBandwidthLimiterClampsBurstToTargetInt(t *testing.T) {
	const bytesPerSecond = int64(1 << 31)

	limiter := NewBandwidthLimiter(bytesPerSecond)
	require.NotNil(t, limiter)

	wantBurst := bytesPerSecond
	maxInt := int64(^uint(0) >> 1)
	if wantBurst > maxInt {
		wantBurst = maxInt
	}
	require.Equal(t, int(wantBurst), limiter.Burst())
	require.Equal(t, rate.Limit(float64(bytesPerSecond)), limiter.Limit())
}

func TestNewBandwidthLimiterDisablesNonPositiveLimit(t *testing.T) {
	require.Nil(t, NewBandwidthLimiter(0))
	require.Nil(t, NewBandwidthLimiter(-1))
}

func TestReaderAndWriterRejectInvalidBurst(t *testing.T) {
	for _, burst := range []int{0, -1} {
		t.Run("reader/"+strconv.Itoa(burst), func(t *testing.T) {
			reader := NewReader(strings.NewReader("payload"), rate.NewLimiter(rate.Limit(1), burst))
			n, err := reader.Read(make([]byte, 1))
			require.Zero(t, n)
			require.EqualError(t, err, "invalid limiter burst: "+strconv.Itoa(burst))
		})

		t.Run("writer/"+strconv.Itoa(burst), func(t *testing.T) {
			var dst bytes.Buffer
			writer := NewWriter(&dst, rate.NewLimiter(rate.Limit(1), burst))
			n, err := writer.Write([]byte("payload"))
			require.Zero(t, n)
			require.EqualError(t, err, "invalid limiter burst: "+strconv.Itoa(burst))
			require.Empty(t, dst.Bytes())
		})
	}
}

func TestReaderAndWriterCancelPendingRateWait(t *testing.T) {
	for _, direction := range []string{"read", "write"} {
		t.Run(direction, func(t *testing.T) {
			limiter := rate.NewLimiter(1, 1)
			require.True(t, limiter.Allow())
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() {
				var err error
				if direction == "read" {
					_, err = NewReaderWithContext(ctx, strings.NewReader("x"), limiter).Read(make([]byte, 1))
				} else {
					_, err = NewWriterWithContext(ctx, io.Discard, limiter).Write([]byte("x"))
				}
				done <- err
			}()
			require.Eventually(t, func() bool { return limiter.Tokens() < -0.5 }, time.Second, time.Millisecond)
			cancel()
			select {
			case err := <-done:
				require.ErrorIs(t, err, context.Canceled)
			case <-time.After(250 * time.Millisecond):
				t.Fatal("rate wait ignored context cancellation")
			}
			require.GreaterOrEqual(t, limiter.Tokens(), float64(0), "canceled reservation must be returned")
		})
	}
}
