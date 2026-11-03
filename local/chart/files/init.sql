\set ON_ERROR_STOP on
CREATE DATABASE auth_db;
\connect auth_db
CREATE TABLE IF NOT EXISTS api_keys (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,

    -- key_hash armazena o hash SHA-256 da chave, que tem 64 caracteres hexadecimais
    key_hash VARCHAR(64) NOT NULL UNIQUE,

    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);


INSERT INTO api_keys(name,key_hash) VALUES ('local-demo','da03b35e680363eaaadd7d4da0a9ca241cacce64f3b6ff076c1cbc5dd9dc58b1') ON CONFLICT DO NOTHING;
CREATE DATABASE flags_db;
\connect flags_db
CREATE TABLE IF NOT EXISTS flags (
    id SERIAL PRIMARY KEY,

    -- 'name' é a chave de negócio única (ex: 'enable-new-checkout')
    name VARCHAR(100) UNIQUE NOT NULL, 
    
    description TEXT,
    
    -- Este é o 'kill switch' global. Se for false, a flag está desativada para todos.
    is_enabled BOOLEAN NOT NULL DEFAULT false,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Opcional, mas boa prática: Trigger para atualizar 'updated_at' automaticamente
CREATE OR REPLACE FUNCTION trigger_set_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Remove o trigger se já existir, para evitar erro na recriação
DROP TRIGGER IF EXISTS set_timestamp ON flags;

CREATE TRIGGER set_timestamp
BEFORE UPDATE ON flags
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_timestamp();

CREATE DATABASE targeting_db;
\connect targeting_db
CREATE TABLE IF NOT EXISTS targeting_rules (
    id SERIAL PRIMARY KEY,

    -- 'flag_name' é a chave de negócio única. 
    -- Cada flag pode ter no máximo UMA regra de segmentação.
    flag_name VARCHAR(100) UNIQUE NOT NULL,
    
    -- Se a regra de segmentação em si está ativa ou não
    is_enabled BOOLEAN NOT NULL DEFAULT true,
    
    -- Armazena a lógica da regra como um JSON.
    -- Ex: {"type": "PERCENTAGE", "value": 50}
    -- Ex: {"type": "USER_LIST", "values": ["u1", "u2"]}
    rules JSONB NOT NULL,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Trigger para atualizar 'updated_at' automaticamente (igual ao do flag-service)
CREATE OR REPLACE FUNCTION trigger_set_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_timestamp ON targeting_rules;

CREATE TRIGGER set_timestamp
BEFORE UPDATE ON targeting_rules
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_timestamp();

