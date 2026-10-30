-- Script de remise à zéro des données opérationnelles de production (Universel Local & VPS)
-- Caisse MYK - Initialisation pour démarrage officiel
-- Conservés : Catalogue, Produits, Fiches techniques, Utilisateurs, Tables, Imprimantes, Paramètres, Prix d'achat unitaires
-- Vidés : Ventes, Caisse, Stocks mouvements, Achats, Cuisine, FNE, Clients tests, Trésorerie

BEGIN;

-- 1. Nettoyage sécurisé : ne vide que les tables existantes (tolère les différences Local vs VPS)
DO $$
DECLARE
    tbl text;
    tbls text[] := ARRAY[
        -- Ventes, commandes, paiements, sessions
        'payments', 'order_items', 'orders', 'fne_documents', 'customers',
        'cash_movements', 'cash_sessions', 'cash_expenses', 'bank_deposits',
        'caisse_journees', 'billetage_comptage', 'cahier_tresorerie',
        'operations_decaissement', 'operations_encaissement', 'autorisations_depense', 'justificatifs',
        -- Stocks, achats, préparations
        'stock_movements', 'raw_material_movements',
        'purchase_request_lines', 'purchase_requests', 'purchase_items', 'purchase_invoices',
        'market_purchase_items', 'market_purchase_lists', 'daily_preparations',
        -- Technique
        'outbox_events', 'idempotency_records', 'print_jobs', 'audit_logs', 'audit_log', 'sequence_counters'
    ];
BEGIN
    FOREACH tbl IN ARRAY tbls LOOP
        IF to_regclass(quote_ident(tbl)) IS NOT NULL THEN
            EXECUTE 'TRUNCATE TABLE ' || quote_ident(tbl) || ' CASCADE';
        END IF;
    END LOOP;
END $$;

-- 2. Remise à 0 des quantités de stock physiques (coûts unitaires d'achat avg_cost_xof conservés)
UPDATE stock_articles SET quantity = 0;

DO $$
BEGIN
    IF to_regclass('stock_items') IS NOT NULL THEN
        UPDATE stock_items SET quantity = 0;
    END IF;
END $$;

COMMIT;
