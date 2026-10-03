# Debug notes

## AIA-0425 package downloads

### Evidence

- Hugging Face package metadata marks model and weight files with `xetHash`; the previous package downloader forced those files through the native Xet client.
- The public `resolve/main/<path>` URL for the affected files serves normal HTTP bytes, so it is a valid transport for every package sibling.
- The observed `3/5` state matches the three ordinary files completing while the two Xet-backed files wait or fail.

### Fix boundary

- Use the public HTTPS resolve URL for every package file, with a maximum of three concurrent transfers.
- Provide actual URLSession byte progress; fail first-byte waits after 20 seconds and stalled transfers after 60 seconds.
- Cancel the real download task and remove the package staging directory on cancellation or failure.

### Offline verification

- Xet-marked files use the HTTP path and report progress.
- Stalled transfers produce the timeout error.
- Cancellation stops the stalled request and leaves no newly-created staging directory.
