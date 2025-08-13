import asyncio
import os
import sys
from aiohttp import web
from pathlib import Path

DEFAULT_PIPE = "/config/pcspk_audio/pcspk_out.raw"
SAMPLE_RATE = 32000
CHANNELS = 1
BITS_PER_SAMPLE = 8
CHUNK_SIZE = 4096

class PipeAudioStreamer:
    def __init__(self, pipe_path):
        self.pipe_path = pipe_path
        self.read_task = None

        # Live-edge distribution state
        self.cond = asyncio.Condition()
        self.seq = 0
        self.latest_chunk = b""

    # ---------- WAV header ----------
    def make_wav_header(self, data_len: int) -> bytes:
        byte_rate = SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE // 8
        block_align = CHANNELS * BITS_PER_SAMPLE // 8
        h = bytearray()
        h += b'RIFF'
        h += (36 + data_len).to_bytes(4, 'little')
        h += b'WAVE'
        h += b'fmt '
        h += (16).to_bytes(4, 'little')
        h += (1).to_bytes(2, 'little')   # PCM
        h += CHANNELS.to_bytes(2, 'little')
        h += SAMPLE_RATE.to_bytes(4, 'little')
        h += byte_rate.to_bytes(4, 'little')
        h += block_align.to_bytes(2, 'little')
        h += BITS_PER_SAMPLE.to_bytes(2, 'little')
        h += b'data'
        h += data_len.to_bytes(4, 'little')
        return bytes(h)

    # ---------- Background FIFO reader (no keepalive writer) ----------
    async def start_reader(self):
        async def read_loop():
            loop = asyncio.get_running_loop()
            while True:
                # Open blocks until a writer connects (done off-thread)
                try:
                    fd = await asyncio.to_thread(os.open, self.pipe_path, os.O_RDONLY)
                except FileNotFoundError:
                    await asyncio.sleep(0.5)
                    continue
                os.set_blocking(fd, False)

                event = asyncio.Event()
                def on_readable():
                    event.set()

                loop.add_reader(fd, on_readable)
                try:
                    while True:
                        await event.wait()
                        event.clear()
                        try:
                            data = os.read(fd, CHUNK_SIZE)
                        except BlockingIOError:
                            continue
                        except OSError:
                            break  # reopen

                        if not data:
                            break  # writer closed -> reopen

                        # Publish latest only; skip history
                        async with self.cond:
                            self.latest_chunk = data
                            self.seq += 1
                            self.cond.notify_all()
                finally:
                    loop.remove_reader(fd)
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                await asyncio.sleep(0.01)  # small backoff

        self.read_task = asyncio.create_task(read_loop())
        print("[INFO] Background pipe reader started (live-edge, no keepalive).")

    # ---------- HTTP handler ----------
    async def stream_wav(self, request: web.Request):
        headers = {
            "Content-Type": "audio/wav",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Transfer-Encoding": "chunked",
        }
        resp = web.StreamResponse(status=200, headers=headers)
        await resp.prepare(request)

        # Each client gets header, then only chunks produced after this point
        await resp.write(self.make_wav_header(0x7FFFFFFF))

        # Record join position; only send when seq advances
        async with self.cond:
            last_seq = self.seq

        try:
            while not request.transport.is_closing():
                async with self.cond:
                    # Wait until a new chunk arrives (seq advances)
                    await self.cond.wait_for(lambda: self.seq != last_seq)
                    last_seq = self.seq
                    chunk = self.latest_chunk
                # Write newest chunk only (missed chunks are skipped)
                try:
                    await resp.write(chunk)
                except (asyncio.CancelledError, ConnectionResetError, BrokenPipeError):
                    break
        finally:
            try:
                await resp.write_eof()
            except Exception:
                pass
        return resp

    async def close(self):
        if self.read_task:
            self.read_task.cancel()
            try:
                await self.read_task
            except Exception:
                pass

async def main(pipe_path):
    if not os.path.exists(pipe_path):
        print(f"[ERROR] Pipe {pipe_path} not found. Create it first: mkfifo {pipe_path}")
        sys.exit(1)

    streamer = PipeAudioStreamer(pipe_path)
    await streamer.start_reader()

    app = web.Application()
    app.router.add_get("/stream.wav", streamer.stream_wav)
    app.router.add_static('/', path=Path(__file__).parent / 'static')

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", 8080)
    await site.start()
    print(f"[INFO] Serving {pipe_path} at http://localhost:8080/stream.wav")

    try:
        while True:
            await asyncio.sleep(3600)
    finally:
        await streamer.close()

if __name__ == "__main__":
    pipe = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PIPE
    try:
        asyncio.run(main(pipe))
    except KeyboardInterrupt:
        print("[INFO] Shutting down.")
