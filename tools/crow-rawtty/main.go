// crow-rawtty applies the binary-safe termios settings required by a MeshCore
// USB CDC Companion port. It is intentionally tiny and has no dependencies so
// it can be cross-compiled as a static helper for stripped-down AREDN images
// that omit stty.
package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// Linux termios baud mask / 115200 values. syscall exposes them on some Go
// targets but not linux/arm, so keep the kernel ABI values explicit.
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

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: crow-rawtty /dev/ttyACM<N>|/dev/ttyUSB<N>")
		os.Exit(2)
	}

	fd, err := syscall.Open(os.Args[1], syscall.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer syscall.Close(fd)

	var termios syscall.Termios
	if err := ioctl(fd, syscall.TCGETS, unsafe.Pointer(&termios)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	termios.Iflag &^= syscall.IGNBRK | syscall.BRKINT | syscall.PARMRK |
		syscall.ISTRIP | syscall.INLCR | syscall.IGNCR | syscall.ICRNL |
		syscall.IXON | syscall.IXOFF | syscall.IXANY
	termios.Oflag &^= syscall.OPOST
	termios.Lflag &^= syscall.ECHO | syscall.ECHONL | syscall.ICANON |
		syscall.ISIG | syscall.IEXTEN
	termios.Cflag &^= syscall.CSIZE | syscall.PARENB | syscall.CSTOPB | cbaud
	termios.Cflag |= syscall.CS8 | syscall.CREAD | syscall.CLOCAL | b115200
	termios.Cc[syscall.VMIN] = 0
	termios.Cc[syscall.VTIME] = 0

	if err := ioctl(fd, syscall.TCSETS, unsafe.Pointer(&termios)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
