class PCMStreamProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.current = null;
    this.offset = 0;

    this.port.onmessage = (event) => {
      const data = event.data;
      if (data instanceof Float32Array) {
        this.queue.push(data);
        this.port.postMessage({ type: 'chunk', size: data.length });
      }
    };
  }

  process(inputs, outputs) {
    const output = outputs[0][0]; // mono output channel
    output.fill(0);

    let i = 0;
    while (i < output.length) {
      if (!this.current || this.offset >= this.current.length) {
        if (this.queue.length === 0) break;
        this.current = this.queue.shift();
        this.offset = 0;
      }

      const remaining = this.current.length - this.offset;
      const toCopy = Math.min(remaining, output.length - i);
      output.set(this.current.subarray(this.offset, this.offset + toCopy), i);
      i += toCopy;
      this.offset += toCopy;
    }

    return true; // Keep alive
  }
}

registerProcessor('pcm-stream-processor', PCMStreamProcessor);
