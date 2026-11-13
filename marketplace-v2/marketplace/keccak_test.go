package main

import (
	"encoding/binary"
	"encoding/hex"
	"math/bits"
	"testing"
)

// Reference Keccak-256 (test-only, so the backend stays dependency-free).
var keccakRC = [24]uint64{
	0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
	0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
	0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
	0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
	0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
	0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
}
var keccakRot = [5][5]int{{0, 36, 3, 41, 18}, {1, 44, 10, 45, 2}, {62, 6, 43, 15, 61}, {28, 55, 25, 21, 56}, {27, 20, 39, 8, 14}}

func keccakF(a *[5][5]uint64) {
	for _, rc := range keccakRC {
		var c, d [5]uint64
		for x := 0; x < 5; x++ {
			c[x] = a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4]
		}
		for x := 0; x < 5; x++ {
			d[x] = c[(x+4)%5] ^ bits.RotateLeft64(c[(x+1)%5], 1)
			for y := 0; y < 5; y++ {
				a[x][y] ^= d[x]
			}
		}
		var b [5][5]uint64
		for x := 0; x < 5; x++ {
			for y := 0; y < 5; y++ {
				b[y][(2*x+3*y)%5] = bits.RotateLeft64(a[x][y], keccakRot[x][y])
			}
		}
		for x := 0; x < 5; x++ {
			for y := 0; y < 5; y++ {
				a[x][y] = b[x][y] ^ (^b[(x+1)%5][y] & b[(x+2)%5][y])
			}
		}
		a[0][0] ^= rc
	}
}

func keccak256Hex(data []byte) string {
	const rate = 136
	p := append([]byte{}, data...)
	p = append(p, 0x01)
	for len(p)%rate != 0 {
		p = append(p, 0)
	}
	p[len(p)-1] |= 0x80
	var a [5][5]uint64
	for i := 0; i < len(p); i += rate {
		for j := 0; j < rate/8; j++ {
			a[j%5][j/5] ^= binary.LittleEndian.Uint64(p[i+8*j:])
		}
		keccakF(&a)
	}
	out := make([]byte, 32)
	for j := 0; j < 4; j++ {
		binary.LittleEndian.PutUint64(out[8*j:], a[j%5][j/5])
	}
	return hex.EncodeToString(out)
}

func TestEventTopicsAreKeccakOfContractSignatures(t *testing.T) {
	if got := keccak256Hex(nil); got != "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470" {
		t.Fatalf("keccak self-test failed: %s", got)
	}
	cases := map[string]string{
		"ListingCreated(uint256,address,string,uint256,uint256)":                listingCreatedTopic,
		"ListingUpdated(uint256,uint256,uint256,bool)":                          listingUpdatedTopic,
		"RentalCreated(uint256,uint256,address,address,string,uint256,uint256)": rentalCreatedTopic,
	}
	for sig, want := range cases {
		if got := "0x" + keccak256Hex([]byte(sig)); got != want {
			t.Errorf("%s: constant %s, keccak %s", sig, want, got)
		}
	}
}
