FROM python:3.11-slim as builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --upgrade pip
RUN pip install --no-cache-dir --user -r requirements.txt

FROM python:3.11-slim
WORKDIR /app
# Aplica patches de segurança do SO disponíveis no momento do build
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
COPY --from=builder /root/.local /root/.local
COPY . .
ENV PATH=/root/.local/bin:$PATH

EXPOSE 8005
CMD ["gunicorn", "--bind", "0.0.0.0:8005", "app:app"]