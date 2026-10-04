# NeMo-Speech.cpp (NVIDIA, Apache 2.0) als HTTP/WebSocket-Server aus dem offiziellen Release-Tarball.
# Der NGC-Container 0.1.0 bietet nur gRPC; das Release v0.2.0 enthält `nemo-speech serve` mit
# OpenAI-kompatiblem /v1/audio/transcriptions, Realtime-WebSocket und Sprechertrennung.
ARG CUDA_IMAGE=nvidia/cuda:13.0.0-runtime-ubuntu24.04
FROM ${CUDA_IMAGE}
ARG NEMO_SPEECH_VERSION=0.2.0
ARG NEMO_SPEECH_FLAVOR=cuda13
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/nemo-speech.tar.gz \
      "https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v${NEMO_SPEECH_VERSION}/nemo-speech-${NEMO_SPEECH_VERSION}-linux-x86_64-${NEMO_SPEECH_FLAVOR}.tar.gz" \
    && mkdir -p /opt/nemo-speech && tar -xzf /tmp/nemo-speech.tar.gz -C /opt/nemo-speech --strip-components=1 \
    && rm /tmp/nemo-speech.tar.gz \
    && ls /opt/nemo-speech
ENV PATH="/opt/nemo-speech/bin:/opt/nemo-speech:${PATH}" \
    LD_LIBRARY_PATH="/opt/nemo-speech/lib:/opt/nemo-speech:${LD_LIBRARY_PATH:-}"
EXPOSE 8080
ENTRYPOINT ["nemo-speech"]
CMD ["serve", "--help"]
