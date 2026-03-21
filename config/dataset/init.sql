CREATE TABLE items (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  url TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE monitoring (
  id SERIAL PRIMARY KEY,
  item_id INT NOT NULL,
  FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE,
  price NUMERIC(10,2) NOT NULL,
  url TEXT NOT NULL,
  timestamp TIMESTAMP NOT NULL,
  discount VARCHAR(255),
  available BOOLEAN
);

CREATE TABLE alerts (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  item_id INT NOT NULL,
  FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE,
  trigger_on_price VARCHAR(255),
  trigger_on_discount BOOLEAN,
  trigger_on_available BOOLEAN,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE notification_channels (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  type VARCHAR(20) CHECK (type IN ('discord', 'webhook')),
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE notification_channels_discord (
  id SERIAL PRIMARY KEY,
  channel_id INT NOT NULL,
  FOREIGN KEY (channel_id) REFERENCES notification_channels(id) ON DELETE CASCADE,
  url VARCHAR(255) NOT NULL,
  message TEXT NOT NULL
);

CREATE TABLE notification_channels_webhook (
  id SERIAL PRIMARY KEY,
  channel_id INT NOT NULL,
  url VARCHAR(255) NOT NULL,
  method VARCHAR(10) NOT NULL CHECK (method IN ('GET', 'POST', 'PUT', 'DELETE', 'PATCH')),
  body TEXT NOT NULL,
  headers TEXT NOT NULL,
  FOREIGN KEY (channel_id) REFERENCES notification_channels(id) ON DELETE CASCADE
);

CREATE TABLE alerts_notification_channels (
    alert_id INT REFERENCES alerts(id) ON DELETE CASCADE,
    channel_id INT REFERENCES notification_channels(id) ON DELETE CASCADE,
    PRIMARY KEY (alert_id, channel_id)
);

CREATE TABLE scraper_remote_sites (
  id                        SERIAL PRIMARY KEY,
  name                      TEXT   NOT NULL,
  urls_match                TEXT[] NOT NULL,
  fields_price_selector      TEXT[] NOT NULL,
  fields_price_transform     TEXT   ,
  fields_price_validate      TEXT   ,
  fields_discount_selector      TEXT[] NOT NULL,
  fields_discount_transform     TEXT   ,
  fields_discount_validate      TEXT   ,
  fields_available_selector      TEXT[] NOT NULL,
  fields_available_transform     TEXT   ,
  fields_available_validate      TEXT   ,
  urls_test                     TEXT[],
  created_at                TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMP NOT NULL DEFAULT NOW()
);
