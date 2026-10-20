# Scholarship Renewal System

HTML + CSS + JavaScript front end, Supabase (Postgres, Auth, Storage) back end.

## Run it
1. Run `schema.sql`, then `seed.sql` in the Supabase SQL Editor.
2. Put your project URL and anon key in `config.js`.
3. `python3 -m http.server 8000` and open http://localhost:8000

## Test logins (password `Password123!`)
`staff@test.com`, `a01@test.com` ... `a06@test.com`

## Where the rules live
Policy numbers are in the `programs` table. The deadline is in the `terms` table.
Access is enforced by Row Level Security. All writes go through database functions.
