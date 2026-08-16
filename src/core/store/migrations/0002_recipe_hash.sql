ALTER TABLE artifacts ADD COLUMN recipe_hash TEXT;
CREATE INDEX IF NOT EXISTS idx_artifacts_recipe_hash ON artifacts(recipe_hash);
