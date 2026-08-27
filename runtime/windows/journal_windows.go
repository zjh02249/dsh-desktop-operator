package main

import (
	"fmt"
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

const (
	waitObject0      = 0x00000000
	waitAbandoned    = 0x00000080
	waitTimeout      = 0x00000102
	moveFileReplace  = 0x00000001
	moveFileWriteThr = 0x00000008
)

var (
	kernel32Journal         = syscall.NewLazyDLL("kernel32.dll")
	procCreateMutexW        = kernel32Journal.NewProc("CreateMutexW")
	procWaitForSingleObject = kernel32Journal.NewProc("WaitForSingleObject")
	procReleaseMutex        = kernel32Journal.NewProc("ReleaseMutex")
	procCloseHandle         = kernel32Journal.NewProc("CloseHandle")
	procMoveFileExW         = kernel32Journal.NewProc("MoveFileExW")
	procOpenProcess         = kernel32Journal.NewProc("OpenProcess")
	procGetExitCodeProcess  = kernel32Journal.NewProc("GetExitCodeProcess")
)

func withNamedMutex(name string, timeoutMS uint32, action func() error) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	namePointer, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return fmt.Errorf("journal_lock_name_invalid: %w", err)
	}
	handle, _, createErr := procCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(namePointer)))
	if handle == 0 {
		return fmt.Errorf("journal_lock_create_failed: %w", createErr)
	}
	defer procCloseHandle.Call(handle)

	waitResult, _, waitErr := procWaitForSingleObject.Call(handle, uintptr(timeoutMS))
	switch waitResult {
	case waitObject0, waitAbandoned:
		defer procReleaseMutex.Call(handle)
		return action()
	case waitTimeout:
		return fmt.Errorf("journal_locked: timed out after %dms", timeoutMS)
	default:
		return fmt.Errorf("journal_lock_wait_failed(result=%d): %w", waitResult, waitErr)
	}
}

func isProcessAlive(processID int) bool {
	if processID <= 0 {
		return false
	}
	if processID == os.Getpid() {
		return true
	}
	const processQueryLimitedInformation = 0x1000
	const stillActive = 259
	const errorInvalidParameter syscall.Errno = 87
	handle, _, openErr := procOpenProcess.Call(processQueryLimitedInformation, 0, uintptr(processID))
	if handle == 0 {
		if errno, ok := openErr.(syscall.Errno); ok && errno == errorInvalidParameter {
			return false
		}
		// Access denied does not prove that the process exited, so fail closed.
		return true
	}
	defer procCloseHandle.Call(handle)
	var exitCode uint32
	result, _, _ := procGetExitCodeProcess.Call(handle, uintptr(unsafe.Pointer(&exitCode)))
	return result != 0 && exitCode == stillActive
}

func replaceFileAtomic(source, destination string) error {
	sourcePointer, err := syscall.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	destinationPointer, err := syscall.UTF16PtrFromString(destination)
	if err != nil {
		return err
	}
	result, _, callErr := procMoveFileExW.Call(
		uintptr(unsafe.Pointer(sourcePointer)),
		uintptr(unsafe.Pointer(destinationPointer)),
		moveFileReplace|moveFileWriteThr,
	)
	if result == 0 {
		return fmt.Errorf("atomic journal replacement failed: %w", callErr)
	}
	return nil
}
