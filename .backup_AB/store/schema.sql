PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS documents (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    title       TEXT NOT NULL,
    path        TEXT NOT NULL,
    page_count  INTEGER DEFAULT 0,
    created_at  TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS concepts (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    document_id  INTEGER NOT NULL REFERENCES documents(id),
    name         TEXT NOT NULL,
    summary      TEXT,
    source_page  INTEGER,
    order_index  INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS misconceptions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    concept_id      INTEGER NOT NULL REFERENCES concepts(id),
    slug            TEXT NOT NULL,
    name            TEXT NOT NULL,
    description     TEXT,
    wrong_model     TEXT,
    correct_model   TEXT,
    artifact_status TEXT DEFAULT 'none'   -- none | card | clip
);

CREATE TABLE IF NOT EXISTS attempts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    concept_id        INTEGER NOT NULL REFERENCES concepts(id),
    question_text     TEXT,
    answer_text       TEXT,
    misconception_id  INTEGER REFERENCES misconceptions(id),  -- NULL = correct
    confidence        REAL,
    evidence_span     TEXT,
    created_at        TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS learner_state (
    concept_id              INTEGER PRIMARY KEY REFERENCES concepts(id),
    mastery                 TEXT DEFAULT 'unseen',
    attempts_count          INTEGER DEFAULT 0,
    active_misconception_id INTEGER REFERENCES misconceptions(id),
    updated_at              TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS llm_cache (
    prompt_hash   TEXT PRIMARY KEY,
    response_json TEXT NOT NULL,
    created_at    TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_concepts_doc ON concepts(document_id);
CREATE INDEX IF NOT EXISTS idx_misc_concept ON misconceptions(concept_id);
CREATE INDEX IF NOT EXISTS idx_attempts_concept ON attempts(concept_id);
