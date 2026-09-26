FROM python:3.12-alpine

WORKDIR /opt/gbrain-allowlist-proxy
COPY server.py ./

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

EXPOSE 3132
CMD ["python3", "server.py"]
