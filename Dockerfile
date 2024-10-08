# base stage
FROM ubuntu:24.04 AS base
USER root

ENV LIGHTEN=0

WORKDIR /ragflow

RUN apt update && apt --no-install-recommends install -y ca-certificates

# if you located in China, you can use tsinghua mirror to speed up apt
RUN  sed -i 's|http://archive.ubuntu.com|https://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/ubuntu.sources

RUN apt update && apt install -y curl libpython3-dev nginx libglib2.0-0 libglx-mesa0 pkg-config libicu-dev libgdiplus python3-poetry \
    && apt clean && rm -rf /var/lib/apt/lists/*

RUN curl -o libssl1.deb http://archive.ubuntu.com/ubuntu/pool/main/o/openssl1.0/libssl1.0.0_1.0.2n-1ubuntu5_amd64.deb && dpkg -i libssl1.deb && rm -f libssl1.deb

ENV PYTHONDONTWRITEBYTECODE=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

# Configure Poetry
ENV POETRY_NO_INTERACTION=1
ENV POETRY_VIRTUALENVS_IN_PROJECT=true
ENV POETRY_VIRTUALENVS_CREATE=true
ENV POETRY_KEYRING_ENABLED=false
ENV POETRY_REQUESTS_TIMEOUT=15

# builder stage
FROM base AS builder
USER root

WORKDIR /ragflow

RUN apt update && apt install -y nodejs npm cargo \
    && apt clean && rm -rf /var/lib/apt/lists/*

COPY web web
RUN cd web && npm i --force && npm run build

# install dependencies from poetry.lock file
COPY pyproject.toml poetry.toml poetry.lock ./

RUN --mount=type=cache,target=/root/.cache/pypoetry,sharing=locked \
    if [ "$LIGHTEN" -eq 0 ]; then \
        poetry install --sync --no-cache --no-root --with=full; \
    else \
        poetry install --sync --no-cache --no-root; \
    fi

# production stage
FROM base AS production
USER root

WORKDIR /ragflow

# Install python packages' dependencies
# cv2 requires libGL.so.1
RUN apt update && apt install -y --no-install-recommends nginx libgl1 vim less \
    && apt clean && rm -rf /var/lib/apt/lists/*

COPY web web
COPY api api
COPY conf conf
COPY deepdoc deepdoc
COPY rag rag
COPY agent agent
COPY graphrag graphrag
COPY pyproject.toml poetry.toml poetry.lock ./

# Copy models downloaded via download_deps.py
RUN mkdir -p /ragflow/rag/res/deepdoc /root/.ragflow
RUN --mount=type=bind,source=huggingface.co,target=/huggingface.co \
    tar --exclude='.*' -cf - \
        /huggingface.co/InfiniFlow/text_concat_xgb_v1.0 \
        /huggingface.co/InfiniFlow/deepdoc \
        | tar -xf - --strip-components=3 -C /ragflow/rag/res/deepdoc
RUN --mount=type=bind,source=huggingface.co,target=/huggingface.co \
    tar -cf - \
        /huggingface.co/BAAI/bge-large-zh-v1.5 \
        /huggingface.co/BAAI/bge-reranker-v2-m3 \
        /huggingface.co/maidalun1020/bce-embedding-base_v1 \
        /huggingface.co/maidalun1020/bce-reranker-base_v1 \
        | tar -xf - --strip-components=2 -C /root/.ragflow

# Copy compiled web pages
COPY --from=builder /ragflow/web/dist /ragflow/web/dist

# Copy Python environment and packages
ENV VIRTUAL_ENV=/ragflow/.venv
COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}
ENV PATH="${VIRTUAL_ENV}/bin:/root/.local/bin:${PATH}"

# Download nltk data
RUN python3 -m nltk.downloader wordnet punkt punkt_tab

ENV PYTHONPATH=/ragflow/

COPY docker/entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
