// crow-serial-probe performs one independent MeshCore Companion transaction.
// It is for field diagnosis only: Crow must be stopped before using it.
package main

import (
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"syscall"
	"time"
	"unsafe"
)

const (
	cbaud   = 0x100f
	b115200 = 0x1002
)

func ioctl(fd int, request uintptr, value unsafe.Pointer) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, uintptr(value))
	if errno != 0 {
		return errno
	}
	return nil
}

func configure(fd int) error {
	var t syscall.Termios
	if err := ioctl(fd, syscall.TCGETS, unsafe.Pointer(&t)); err != nil {
		return err
	}
	t.Iflag &^= syscall.IGNBRK | syscall.BRKINT | syscall.PARMRK | syscall.ISTRIP |
		syscall.INLCR | syscall.IGNCR | syscall.ICRNL | syscall.IXON | syscall.IXOFF | syscall.IXANY
	t.Oflag &^= syscall.OPOST
	t.Lflag &^= syscall.ECHO | syscall.ECHONL | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	t.Cflag &^= syscall.CSIZE | syscall.PARENB | syscall.CSTOPB | cbaud
	t.Cflag |= syscall.CS8 | syscall.CREAD | syscall.CLOCAL | b115200
	t.Cc[syscall.VMIN], t.Cc[syscall.VTIME] = 0, 0
	return ioctl(fd, syscall.TCSETS, unsafe.Pointer(&t))
}

func frame(profile string) []byte {
	reserved := []byte{0, 0, 0, 0, 0, 0, 0}
	if profile == "cli" {
		reserved[0] = 3
		for i := 1; i < len(reserved); i++ {
			reserved[i] = ' '
		}
	}
	p := append([]byte{1}, append(reserved, []byte("Crow")...)...)
	return append([]byte{'<', byte(len(p)), 0}, p...)
}

func main() {
	device := flag.String("device", "/dev/ttyACM0", "serial device")
	profile := flag.String("profile", "zeros", "zeros or cli")
	seconds := flag.Int("seconds", 5, "response wait time")
	split := flag.Bool("split", false, "use separate read/write descriptors")
	flag.Parse()
	f := frame(*profile)
	fmt.Printf("profile=%s split=%t tx=%s\n", *profile, *split, hex.EncodeToString(f))
	fd, txfd := -1, -1
	var err error
	if *split {
		fd, err = syscall.Open(*device, syscall.O_RDONLY|syscall.O_NOCTTY|syscall.O_NONBLOCK, 0)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		txfd, err = syscall.Open(*device, syscall.O_WRONLY|syscall.O_NOCTTY|syscall.O_NONBLOCK, 0)
		if err != nil {
			syscall.Close(fd)
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		ctl, e := syscall.Open(*device, syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_NONBLOCK, 0)
		if e != nil {
			syscall.Close(fd)
			syscall.Close(txfd)
			fmt.Fprintln(os.Stderr, e)
			os.Exit(1)
		}
		err = configure(ctl)
		syscall.Close(ctl)
	} else {
		fd, err = syscall.Open(*device, syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_NONBLOCK, 0)
		txfd = fd
		if err == nil {
			err = configure(fd)
		}
	}
	if err != nil {
		if txfd != fd {
			syscall.Close(txfd)
		}
		syscall.Close(fd)
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer syscall.Close(fd)
	if txfd != fd {
		defer syscall.Close(txfd)
	}
	// Discard stale bytes, then send after a short CDC-open settling period.
	var stale [4096]byte
	for {
		n, e := syscall.Read(fd, stale[:])
		if n == 0 || e != nil {
			break
		}
	}
	time.Sleep(2 * time.Second)
	if n, e := syscall.Write(txfd, f); e != nil || n != len(f) {
		fmt.Fprintf(os.Stderr, "write=%d err=%v\n", n, e)
		os.Exit(1)
	}
	deadline := time.Now().Add(time.Duration(*seconds) * time.Second)
	var got []byte
	buf := make([]byte, 2048)
	for time.Now().Before(deadline) {
		n, e := syscall.Read(fd, buf)
		if n > 0 {
			got = append(got, buf[:n]...)
			fmt.Printf("rx=%s\n", hex.EncodeToString(buf[:n]))
		}
		if e != nil && e != syscall.EAGAIN && e != syscall.EWOULDBLOCK {
			fmt.Fprintf(os.Stderr, "read err=%v\n", e)
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	fmt.Printf("rx_bytes=%d\n", len(got))
}
