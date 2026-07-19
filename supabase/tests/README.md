# Supabase regression tests

SQL files in this directory are designed to run inside an explicit transaction and end with `rollback;`. They validate database contracts without leaving test rows behind.
