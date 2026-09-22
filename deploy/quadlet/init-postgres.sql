-- Teleport PostgreSQL Database Initialization Script
ALTER USER teleport_user WITH REPLICATION;
CREATE DATABASE teleport_audit WITH OWNER teleport_user;
GRANT ALL PRIVILEGES ON DATABASE teleport_state TO teleport_user;
GRANT ALL PRIVILEGES ON DATABASE teleport_audit TO teleport_user;
