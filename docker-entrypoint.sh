#!/bin/bash
set -e

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL..."
while ! pg_isready -h "$DATABASE_HOST" -U postgres -q; do
  sleep 1
done
echo "PostgreSQL is ready!"

# Run migrations
echo "Running migrations..."
mix ecto.create --quiet
mix ecto.migrate

# Start the server
echo "Starting Phoenix server..."
exec mix phx.server
