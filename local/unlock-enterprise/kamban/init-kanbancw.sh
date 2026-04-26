#!/bin/sh
# Cria usuário e banco do Kanban (idempotente).
# 1ª inicialização: volume vazio + /docker-entrypoint-initdb.d no postgrespgvector
# Cluster já existente: docker exec -i <container_pgvector> sh -s < init-kanbancw.sh
# Use finais de linha LF (Unix); CRLF quebra "set -eu" no Linux.
set -eu

POSTGRES_USER="${POSTGRES_USER:-postgres}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'EOSQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kanbancw') THEN
    CREATE USER kanbancw WITH PASSWORD 'kanbancw_secret_2024';
  END IF;
END
$$;
EOSQL

DB_EXISTS=$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'kanbancw'")
if [ -z "$DB_EXISTS" ]; then
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c "CREATE DATABASE kanbancw OWNER kanbancw;"
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname kanbancw <<'EOSQL'
GRANT ALL ON SCHEMA public TO kanbancw;
GRANT CREATE ON SCHEMA public TO kanbancw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO kanbancw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO kanbancw;
EOSQL
