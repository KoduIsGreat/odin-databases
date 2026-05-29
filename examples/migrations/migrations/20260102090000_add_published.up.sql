ALTER TABLE articles ADD COLUMN published INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_articles_published ON articles (published);
