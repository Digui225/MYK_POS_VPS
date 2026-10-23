FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app

FROM base AS build
COPY pyproject.toml README.md ./
COPY src ./src
RUN pip install --prefix=/install .

FROM base AS runtime
RUN useradd --create-home --uid 1000 caisse
COPY --from=build /install /usr/local
COPY alembic.ini ./
COPY alembic ./alembic
COPY src ./src
USER caisse
EXPOSE 8000
CMD ["uvicorn", "caisse.main:app", "--host", "0.0.0.0", "--port", "8000"]
