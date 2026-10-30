-- Script de remise à zéro des données opérationnelles de production
-- Caisse MYK - Initialisation pour démarrage officiel
-- Conservés : Catalogue, Produits, Fiches techniques, Utilisateurs, Tables, Imprimantes, Paramètres, Prix d'achat unitaires
-- Vidés : Ventes, Caisse, Stocks mouvements, Achats, Cuisine, FNE, Clients tests, Trésorerie

BEGIN;

-- 1. Ventes, Commandes, Caisse & Règlements
TRUNCATE TABLE
    payments,
    order_items,
    orders,
    fne_documents,
    customers,
    cash_movements,
    cash_sessions,
    caisse_journees,
    billetage_comptage,
    cahier_tresorerie,
    operations_decaissement,
    operations_encaissement,
    autorisations_depense,
    justificatifs,
    cash_expenses,
    bank_deposits
CASCADE;

-- 2. Stocks mouvements, Achats & Préparations cuisine
TRUNCATE TABLE
    stock_movements,
    raw_material_movements,
    purchase_request_lines,
    purchase_requests,
    purchase_items,
    purchase_invoices,
    market_purchase_items,
    market_purchase_lists,
    daily_preparations
CASCADE;

-- 3. Technique : Outbox, Idempotence, Impressions, Audit, Séquences
TRUNCATE TABLE
    outbox_events,
    idempotency_records,
    print_jobs,
    audit_logs,
    audit_log,
    sequence_counters
CASCADE;

-- 4. Remise à 0 des quantités de stock physiques (coûts d'achat unitaires avg_cost_xof conservés)
UPDATE stock_articles SET quantity = 0;
UPDATE stock_items SET quantity = 0;

COMMIT;
