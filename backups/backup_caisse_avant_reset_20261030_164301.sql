--
-- PostgreSQL database dump
--

\restrict L8rFUxjqAEBLCgHzmhbaf4v23CdfnKTzFhqS1xaNDTImudqXW52WQSggVPa3MXw

-- Dumped from database version 15.19
-- Dumped by pg_dump version 15.19

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: role_utilisateur; Type: TYPE; Schema: public; Owner: caisse_user
--

CREATE TYPE public.role_utilisateur AS ENUM (
    'caissier',
    'gestionnaire',
    'responsable',
    'admin'
);


ALTER TYPE public.role_utilisateur OWNER TO caisse_user;

--
-- Name: statut_autorisation; Type: TYPE; Schema: public; Owner: caisse_user
--

CREATE TYPE public.statut_autorisation AS ENUM (
    'en_attente',
    'approuvee',
    'refusee'
);


ALTER TYPE public.statut_autorisation OWNER TO caisse_user;

--
-- Name: statut_journee; Type: TYPE; Schema: public; Owner: caisse_user
--

CREATE TYPE public.statut_journee AS ENUM (
    'ouverte',
    'cloturee',
    'validee',
    'rejetee',
    'archivee'
);


ALTER TYPE public.statut_journee OWNER TO caisse_user;

--
-- Name: type_encaissement; Type: TYPE; Schema: public; Owner: caisse_user
--

CREATE TYPE public.type_encaissement AS ENUM (
    'vente',
    'approvisionnement'
);


ALTER TYPE public.type_encaissement OWNER TO caisse_user;

--
-- Name: type_mouvement_tresorerie; Type: TYPE; Schema: public; Owner: caisse_user
--

CREATE TYPE public.type_mouvement_tresorerie AS ENUM (
    'augmentation',
    'diminution',
    'ajustement'
);


ALTER TYPE public.type_mouvement_tresorerie OWNER TO caisse_user;

--
-- Name: alimenter_cahier_tresorerie(); Type: FUNCTION; Schema: public; Owner: caisse_user
--

CREATE FUNCTION public.alimenter_cahier_tresorerie() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_solde_avant NUMERIC(14,2);
    v_variation   NUMERIC(14,2);
    v_solde_apres NUMERIC(14,2);
    v_type        type_mouvement_tresorerie;
    v_libelle     VARCHAR(255);
BEGIN
    IF NEW.statut = 'validee' AND (OLD.statut IS NULL OR OLD.statut IS DISTINCT FROM 'validee') THEN
        -- Récupérer le dernier solde de trésorerie disponible pour cette superette
        SELECT solde_apres INTO v_solde_avant
        FROM cahier_tresorerie
        WHERE superette_id = NEW.superette_id
        ORDER BY date_mouvement DESC, id DESC
        LIMIT 1;

        -- Si première session de trésorerie pour cette superette
        IF v_solde_avant IS NULL THEN
            v_solde_avant := 0;
            v_variation := COALESCE(NEW.solde_theorique, 0);
            v_solde_apres := v_variation;
        ELSE
            -- Variation nette d'exploitation de la journée = Recettes - Dépenses
            v_variation := COALESCE(NEW.solde_theorique, 0) - COALESCE(NEW.solde_veille, 0);
            v_solde_apres := v_solde_avant + v_variation;
        END IF;

        IF v_variation > 0 THEN
            v_type := 'augmentation'::type_mouvement_tresorerie;
            v_libelle := 'Flux net caisse du ' || NEW.date_operation::text || ' (+ Recettes nettes)';
        ELSIF v_variation < 0 THEN
            v_type := 'diminution'::type_mouvement_tresorerie;
            v_libelle := 'Flux net caisse du ' || NEW.date_operation::text || ' (- Dépenses nettes)';
        ELSE
            v_type := 'ajustement'::type_mouvement_tresorerie;
            v_libelle := 'Flux net caisse équilibré du ' || NEW.date_operation::text;
        END IF;

        INSERT INTO cahier_tresorerie (
            superette_id, caisse_journee_id, date_mouvement, type_mouvement,
            libelle, montant, solde_avant, solde_apres, saisi_par
        ) VALUES (
            NEW.superette_id, NEW.id, NEW.date_operation, v_type,
            v_libelle,
            ABS(v_variation), v_solde_avant, v_solde_apres,
            NEW.validee_par
        );
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.alimenter_cahier_tresorerie() OWNER TO caisse_user;

--
-- Name: empecher_modif_journee_cloturee(); Type: FUNCTION; Schema: public; Owner: caisse_user
--

CREATE FUNCTION public.empecher_modif_journee_cloturee() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_statut statut_journee;
DECLARE v_journee_id INTEGER;
BEGIN
    v_journee_id := COALESCE(NEW.caisse_journee_id, OLD.caisse_journee_id);
    SELECT statut INTO v_statut FROM caisse_journees WHERE id = v_journee_id;
    IF v_statut IN ('cloturee', 'validee', 'archivee') THEN
        RAISE EXCEPTION 'Journée déjà soumise/validée : modification interdite sur la journée ID %', v_journee_id
            USING ERRCODE = 'CA001';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION public.empecher_modif_journee_cloturee() OWNER TO caisse_user;

--
-- Name: recalculer_totaux_journee(integer); Type: FUNCTION; Schema: public; Owner: caisse_user
--

CREATE FUNCTION public.recalculer_totaux_journee(p_journee_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE caisse_journees cj SET
        total_encaissements = COALESCE((SELECT SUM(montant) FROM operations_encaissement WHERE caisse_journee_id = p_journee_id), 0),
        total_decaissements = COALESCE((SELECT SUM(montant) FROM operations_decaissement WHERE caisse_journee_id = p_journee_id), 0),
        total_billetage     = COALESCE((SELECT SUM(bc.nombre * d.valeur) FROM billetage_comptage bc JOIN denominations d ON d.id = bc.denomination_id WHERE bc.caisse_journee_id = p_journee_id), 0),
        billetage_effectue  = EXISTS(SELECT 1 FROM billetage_comptage WHERE caisse_journee_id = p_journee_id)
    WHERE cj.id = p_journee_id;
END;
$$;


ALTER FUNCTION public.recalculer_totaux_journee(p_journee_id integer) OWNER TO caisse_user;

--
-- Name: trg_recalculer_totaux(); Type: FUNCTION; Schema: public; Owner: caisse_user
--

CREATE FUNCTION public.trg_recalculer_totaux() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_journee_id INTEGER;
BEGIN
    v_journee_id := COALESCE(NEW.caisse_journee_id, OLD.caisse_journee_id);
    IF v_journee_id IS NOT NULL THEN
        PERFORM recalculer_totaux_journee(v_journee_id);
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION public.trg_recalculer_totaux() OWNER TO caisse_user;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: alembic_version; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.alembic_version (
    version_num character varying(32) NOT NULL
);


ALTER TABLE public.alembic_version OWNER TO caisse_user;

--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    utilisateur_id integer,
    table_cible character varying(100) NOT NULL,
    ligne_id integer,
    action character varying(20) NOT NULL,
    ancienne_valeur jsonb,
    nouvelle_valeur jsonb,
    date_action timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.audit_log OWNER TO caisse_user;

--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.audit_log_id_seq OWNER TO caisse_user;

--
-- Name: audit_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.audit_log_id_seq OWNED BY public.audit_log.id;


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.audit_logs (
    id character varying(36) NOT NULL,
    user_id character varying(36),
    acting_as_user_id character varying(36),
    action character varying(50) NOT NULL,
    entity character varying(50) NOT NULL,
    entity_id character varying(36),
    before json,
    after json,
    reason character varying(255),
    device_id character varying(100),
    ip character varying(50),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.audit_logs OWNER TO caisse_user;

--
-- Name: autorisations_depense; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.autorisations_depense (
    id integer NOT NULL,
    caisse_journee_id integer,
    demandeur character varying(150) NOT NULL,
    date_demande date NOT NULL,
    dossier character varying(150),
    objet character varying(255),
    montant numeric(14,2) NOT NULL,
    statut public.statut_autorisation DEFAULT 'en_attente'::public.statut_autorisation NOT NULL,
    approuve_par integer,
    approuve_le timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT autorisations_depense_montant_check CHECK ((montant >= (0)::numeric))
);


ALTER TABLE public.autorisations_depense OWNER TO caisse_user;

--
-- Name: autorisations_depense_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.autorisations_depense_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.autorisations_depense_id_seq OWNER TO caisse_user;

--
-- Name: autorisations_depense_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.autorisations_depense_id_seq OWNED BY public.autorisations_depense.id;


--
-- Name: bank_deposits; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.bank_deposits (
    id character varying(36) NOT NULL,
    business_date date NOT NULL,
    user_id character varying(36) NOT NULL,
    amount_xof integer NOT NULL,
    bank_name character varying(100) NOT NULL,
    slip_number character varying(100) NOT NULL,
    deposited_by character varying(100),
    notes character varying(255),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.bank_deposits OWNER TO caisse_user;

--
-- Name: billetage_comptage; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.billetage_comptage (
    id integer NOT NULL,
    caisse_journee_id integer NOT NULL,
    denomination_id integer NOT NULL,
    nombre integer DEFAULT 0 NOT NULL,
    CONSTRAINT billetage_comptage_nombre_check CHECK ((nombre >= 0))
);


ALTER TABLE public.billetage_comptage OWNER TO caisse_user;

--
-- Name: billetage_comptage_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.billetage_comptage_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.billetage_comptage_id_seq OWNER TO caisse_user;

--
-- Name: billetage_comptage_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.billetage_comptage_id_seq OWNED BY public.billetage_comptage.id;


--
-- Name: cahier_tresorerie; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.cahier_tresorerie (
    id integer NOT NULL,
    superette_id integer NOT NULL,
    caisse_journee_id integer,
    date_mouvement date NOT NULL,
    type_mouvement public.type_mouvement_tresorerie NOT NULL,
    libelle character varying(255) NOT NULL,
    montant numeric(14,2) NOT NULL,
    solde_avant numeric(14,2) NOT NULL,
    solde_apres numeric(14,2) NOT NULL,
    saisi_par integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT cahier_tresorerie_montant_check CHECK ((montant >= (0)::numeric))
);


ALTER TABLE public.cahier_tresorerie OWNER TO caisse_user;

--
-- Name: cahier_tresorerie_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.cahier_tresorerie_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.cahier_tresorerie_id_seq OWNER TO caisse_user;

--
-- Name: cahier_tresorerie_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.cahier_tresorerie_id_seq OWNED BY public.cahier_tresorerie.id;


--
-- Name: caisse_journees; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.caisse_journees (
    id integer NOT NULL,
    superette_id integer NOT NULL,
    date_operation date NOT NULL,
    solde_veille numeric(14,2) DEFAULT 0 NOT NULL,
    total_encaissements numeric(14,2) DEFAULT 0 NOT NULL,
    total_decaissements numeric(14,2) DEFAULT 0 NOT NULL,
    solde_theorique numeric(14,2) GENERATED ALWAYS AS (((solde_veille + total_encaissements) - total_decaissements)) STORED,
    total_billetage numeric(14,2) DEFAULT 0 NOT NULL,
    commentaire_ecart text,
    statut public.statut_journee DEFAULT 'ouverte'::public.statut_journee NOT NULL,
    ouverte_par integer,
    cloturee_par integer,
    cloturee_le timestamp with time zone,
    validee_par integer,
    validee_le timestamp with time zone,
    commentaire_validation text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    billetage_effectue boolean DEFAULT false NOT NULL,
    ecart numeric(14,2) GENERATED ALWAYS AS (
CASE
    WHEN billetage_effectue THEN (total_billetage - ((solde_veille + total_encaissements) - total_decaissements))
    ELSE NULL::numeric
END) STORED,
    CONSTRAINT caisse_journees_check CHECK (((validee_par IS NULL) OR (validee_par <> cloturee_par)))
);


ALTER TABLE public.caisse_journees OWNER TO caisse_user;

--
-- Name: caisse_journees_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.caisse_journees_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.caisse_journees_id_seq OWNER TO caisse_user;

--
-- Name: caisse_journees_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.caisse_journees_id_seq OWNED BY public.caisse_journees.id;


--
-- Name: cash_expenses; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.cash_expenses (
    id character varying(36) NOT NULL,
    business_date date NOT NULL,
    cash_session_id character varying(36),
    user_id character varying(36) NOT NULL,
    category character varying(50) NOT NULL,
    amount_xof integer NOT NULL,
    recipient character varying(100),
    reason character varying(255) NOT NULL,
    receipt_reference character varying(100),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.cash_expenses OWNER TO caisse_user;

--
-- Name: cash_movements; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.cash_movements (
    id character varying(36) NOT NULL,
    cash_session_id character varying(36) NOT NULL,
    user_id character varying(36) NOT NULL,
    type character varying(10) NOT NULL,
    amount_xof integer NOT NULL,
    reason character varying(255) NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.cash_movements OWNER TO caisse_user;

--
-- Name: cash_registers; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.cash_registers (
    id character varying(36) NOT NULL,
    name character varying(50) NOT NULL,
    printer_config json,
    is_active boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.cash_registers OWNER TO caisse_user;

--
-- Name: cash_sessions; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.cash_sessions (
    id character varying(36) NOT NULL,
    cash_register_id character varying(36) NOT NULL,
    opened_by_user_id character varying(36) NOT NULL,
    closed_by_user_id character varying(36),
    business_date date NOT NULL,
    status character varying(20) NOT NULL,
    opening_float_xof integer NOT NULL,
    opened_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone,
    z_number integer,
    expected_cash_xof integer,
    counted_cash_xof integer,
    variance_xof integer,
    closing_breakdown json,
    totals_snapshot json,
    notes character varying(500),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.cash_sessions OWNER TO caisse_user;

--
-- Name: categories; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.categories (
    id character varying(36) NOT NULL,
    name character varying(100) NOT NULL,
    kind character varying(20) NOT NULL,
    sort_order integer NOT NULL,
    color character varying(20),
    fiscal_group character varying(50),
    is_active boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.categories OWNER TO caisse_user;

--
-- Name: categories_depense; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.categories_depense (
    id integer NOT NULL,
    libelle character varying(100) NOT NULL,
    description text
);


ALTER TABLE public.categories_depense OWNER TO caisse_user;

--
-- Name: categories_depense_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.categories_depense_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.categories_depense_id_seq OWNER TO caisse_user;

--
-- Name: categories_depense_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.categories_depense_id_seq OWNED BY public.categories_depense.id;


--
-- Name: customers; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.customers (
    id character varying(36) NOT NULL,
    name character varying(200) NOT NULL,
    ncc character varying(50),
    phone character varying(50),
    email character varying(100),
    address character varying(255),
    is_active boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    tax_regime character varying(50)
);


ALTER TABLE public.customers OWNER TO caisse_user;

--
-- Name: daily_preparations; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.daily_preparations (
    id character varying(36) NOT NULL,
    business_date date NOT NULL,
    article_id character varying(36) NOT NULL,
    prepared_quantity numeric(12,3) NOT NULL,
    yield_portions_per_unit numeric(6,2) NOT NULL,
    theoretical_dishes integer NOT NULL,
    user_id character varying(36) NOT NULL,
    notes character varying(255),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_daily_prep_dishes_positive CHECK ((theoretical_dishes >= 0)),
    CONSTRAINT ck_daily_prep_qty_positive CHECK ((prepared_quantity > (0)::numeric)),
    CONSTRAINT ck_daily_prep_yield_positive CHECK ((yield_portions_per_unit > (0)::numeric))
);


ALTER TABLE public.daily_preparations OWNER TO caisse_user;

--
-- Name: denominations; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.denominations (
    id integer NOT NULL,
    valeur numeric(12,2) NOT NULL,
    type character varying(10) DEFAULT 'billet'::character varying NOT NULL,
    actif boolean DEFAULT true NOT NULL,
    CONSTRAINT denominations_type_check CHECK (((type)::text = ANY ((ARRAY['billet'::character varying, 'piece'::character varying])::text[])))
);


ALTER TABLE public.denominations OWNER TO caisse_user;

--
-- Name: denominations_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.denominations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.denominations_id_seq OWNER TO caisse_user;

--
-- Name: denominations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.denominations_id_seq OWNED BY public.denominations.id;


--
-- Name: establishment_settings; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.establishment_settings (
    id character varying(36) NOT NULL,
    restaurant_name character varying(100) NOT NULL,
    ncc character varying(50) NOT NULL,
    rccm character varying(50) NOT NULL,
    address character varying(255) NOT NULL,
    phone character varying(50) NOT NULL,
    default_vat_rate double precision NOT NULL,
    receipt_footer character varying(255) NOT NULL,
    print_width integer NOT NULL,
    screen_lock_timeout_seconds integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.establishment_settings OWNER TO caisse_user;

--
-- Name: fne_documents; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.fne_documents (
    id character varying(36) NOT NULL,
    order_id character varying(36) NOT NULL,
    customer_id character varying(36),
    document_type character varying(20) DEFAULT 'FNE'::character varying,
    status character varying(20) NOT NULL,
    invoice_number character varying(100),
    qr_url character varying(500),
    fne_token character varying(64),
    payload json NOT NULL,
    response_payload json,
    error_message text,
    retry_count integer DEFAULT 0,
    submitted_at timestamp with time zone,
    certified_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    type character varying(20) DEFAULT 'FNE'::character varying NOT NULL,
    template character varying(8),
    cash_session_id character varying(36),
    parent_document_id character varying(36),
    fne_invoice_id character varying(64),
    items_map json,
    fne_amount_ttc_xof integer,
    sticker_balance integer,
    is_uncertain boolean DEFAULT false NOT NULL,
    created_by_user_id character varying(36),
    external_number character varying(64),
    qr_payload text,
    raw_response json,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text,
    next_retry_at timestamp with time zone
);


ALTER TABLE public.fne_documents OWNER TO caisse_user;

--
-- Name: fournisseurs; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.fournisseurs (
    id integer NOT NULL,
    nom character varying(150) NOT NULL,
    contact character varying(100),
    telephone character varying(30),
    actif boolean DEFAULT true NOT NULL
);


ALTER TABLE public.fournisseurs OWNER TO caisse_user;

--
-- Name: fournisseurs_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.fournisseurs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.fournisseurs_id_seq OWNER TO caisse_user;

--
-- Name: fournisseurs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.fournisseurs_id_seq OWNED BY public.fournisseurs.id;


--
-- Name: idempotency_records; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.idempotency_records (
    key character varying(100) NOT NULL,
    request_path character varying(255) NOT NULL,
    request_hash character varying(64) NOT NULL,
    response_status integer NOT NULL,
    response_body json NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.idempotency_records OWNER TO caisse_user;

--
-- Name: justificatifs; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.justificatifs (
    id integer NOT NULL,
    operation_decaissement_id integer,
    nom_fichier character varying(255),
    chemin_fichier text NOT NULL,
    type_document character varying(50),
    uploaded_by integer,
    uploaded_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.justificatifs OWNER TO caisse_user;

--
-- Name: justificatifs_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.justificatifs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.justificatifs_id_seq OWNER TO caisse_user;

--
-- Name: justificatifs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.justificatifs_id_seq OWNED BY public.justificatifs.id;


--
-- Name: market_purchase_items; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.market_purchase_items (
    id character varying(36) NOT NULL,
    purchase_list_id character varying(36) NOT NULL,
    article_id character varying(36) NOT NULL,
    quantity numeric(12,3) NOT NULL,
    unit_price_xof integer NOT NULL,
    total_price_xof integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_market_purchase_items_qty_positive CHECK ((quantity > (0)::numeric)),
    CONSTRAINT ck_market_purchase_items_total_price_positive CHECK ((total_price_xof >= 0)),
    CONSTRAINT ck_market_purchase_items_unit_price_positive CHECK ((unit_price_xof >= 0))
);


ALTER TABLE public.market_purchase_items OWNER TO caisse_user;

--
-- Name: market_purchase_lists; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.market_purchase_lists (
    id character varying(36) NOT NULL,
    business_date date NOT NULL,
    status character varying(20) NOT NULL,
    created_by_user_id character varying(36) NOT NULL,
    validated_by_user_id character varying(36),
    total_budget_xof integer NOT NULL,
    notes character varying(255),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_market_purchase_lists_budget_positive CHECK ((total_budget_xof >= 0))
);


ALTER TABLE public.market_purchase_lists OWNER TO caisse_user;

--
-- Name: operations_decaissement; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.operations_decaissement (
    id integer NOT NULL,
    caisse_journee_id integer NOT NULL,
    date_operation date NOT NULL,
    objet character varying(150),
    designation character varying(255),
    categorie_id integer,
    fournisseur_id integer,
    executant_id integer,
    n_facture character varying(50),
    n_piece_caisse character varying(50),
    montant numeric(14,2) NOT NULL,
    autorisation_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT operations_decaissement_montant_check CHECK ((montant >= (0)::numeric))
);


ALTER TABLE public.operations_decaissement OWNER TO caisse_user;

--
-- Name: operations_decaissement_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.operations_decaissement_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.operations_decaissement_id_seq OWNER TO caisse_user;

--
-- Name: operations_decaissement_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.operations_decaissement_id_seq OWNED BY public.operations_decaissement.id;


--
-- Name: operations_encaissement; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.operations_encaissement (
    id integer NOT NULL,
    caisse_journee_id integer NOT NULL,
    type_encaissement public.type_encaissement NOT NULL,
    date_operation date NOT NULL,
    libelle character varying(255),
    montant numeric(14,2) NOT NULL,
    executant_id integer,
    n_bon_caisse character varying(50),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT operations_encaissement_montant_check CHECK ((montant >= (0)::numeric))
);


ALTER TABLE public.operations_encaissement OWNER TO caisse_user;

--
-- Name: operations_encaissement_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.operations_encaissement_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.operations_encaissement_id_seq OWNER TO caisse_user;

--
-- Name: operations_encaissement_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.operations_encaissement_id_seq OWNED BY public.operations_encaissement.id;


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.order_items (
    id character varying(36) NOT NULL,
    order_id character varying(36) NOT NULL,
    product_id character varying(36),
    product_name_snapshot character varying(150) NOT NULL,
    category_snapshot character varying(100) NOT NULL,
    unit_price_xof integer NOT NULL,
    quantity integer NOT NULL,
    vat_rate numeric(4,2) NOT NULL,
    line_total_xof integer NOT NULL,
    note character varying(255),
    added_by_user_id character varying(36) NOT NULL,
    added_at timestamp with time zone NOT NULL,
    removed_at timestamp with time zone,
    removed_by_user_id character varying(36),
    removal_reason character varying(255),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.order_items OWNER TO caisse_user;

--
-- Name: orders; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.orders (
    id character varying(36) NOT NULL,
    order_number character varying(50) NOT NULL,
    cash_session_id character varying(36) NOT NULL,
    table_id character varying(36),
    status character varying(20) NOT NULL,
    opened_by_user_id character varying(36) NOT NULL,
    closed_by_user_id character varying(36),
    guests_count integer NOT NULL,
    total_ttc_xof integer NOT NULL,
    total_ht_xof integer NOT NULL,
    total_vat_xof integer NOT NULL,
    paid_xof integer NOT NULL,
    due_xof integer NOT NULL,
    cancelled_reason character varying(255),
    cancelled_by_user_id character varying(36),
    cancelled_at timestamp with time zone,
    opened_at timestamp with time zone NOT NULL,
    paid_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    note_label character varying(50)
);


ALTER TABLE public.orders OWNER TO caisse_user;

--
-- Name: outbox_events; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.outbox_events (
    id character varying(36) NOT NULL,
    event_type character varying(50) NOT NULL,
    aggregate_type character varying(50) NOT NULL,
    aggregate_id character varying(36) NOT NULL,
    payload json NOT NULL,
    status character varying(20) NOT NULL,
    retry_count integer NOT NULL,
    next_retry_at timestamp with time zone,
    last_error text,
    processed_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.outbox_events OWNER TO caisse_user;

--
-- Name: payments; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.payments (
    id character varying(36) NOT NULL,
    order_id character varying(36) NOT NULL,
    cash_session_id character varying(36) NOT NULL,
    user_id character varying(36) NOT NULL,
    method character varying(20) NOT NULL,
    amount_xof integer NOT NULL,
    tendered_xof integer,
    change_xof integer,
    provider character varying(50),
    reference character varying(100),
    status character varying(20) NOT NULL,
    idempotency_key character varying(100),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.payments OWNER TO caisse_user;

--
-- Name: print_jobs; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.print_jobs (
    id character varying(36) NOT NULL,
    order_id character varying(36),
    job_type character varying(30) NOT NULL,
    status character varying(20) NOT NULL,
    content text NOT NULL,
    open_drawer boolean NOT NULL,
    cut boolean NOT NULL,
    is_duplicate boolean NOT NULL,
    error_message text,
    printed_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    claimed_at timestamp with time zone,
    terminal_id character varying(36),
    attempts integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.print_jobs OWNER TO caisse_user;

--
-- Name: print_terminals; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.print_terminals (
    id character varying(36) NOT NULL,
    name character varying(60) NOT NULL,
    token_hash character varying(64) NOT NULL,
    revoked_at timestamp with time zone,
    last_seen_at timestamp with time zone,
    printer_status json DEFAULT '{}'::json NOT NULL,
    created_by character varying(36),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.print_terminals OWNER TO caisse_user;

--
-- Name: product_components; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.product_components (
    id character varying(36) NOT NULL,
    product_id character varying(36) NOT NULL,
    article_id character varying(36) NOT NULL,
    quantity numeric(12,3) NOT NULL,
    CONSTRAINT ck_product_components_quantity_positive CHECK ((quantity > (0)::numeric))
);


ALTER TABLE public.product_components OWNER TO caisse_user;

--
-- Name: product_price_history; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.product_price_history (
    id character varying(36) NOT NULL,
    product_id character varying(36) NOT NULL,
    old_price_xof integer NOT NULL,
    new_price_xof integer NOT NULL,
    changed_by_user_id character varying(36) NOT NULL,
    changed_at timestamp with time zone NOT NULL,
    reason character varying(255) NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.product_price_history OWNER TO caisse_user;

--
-- Name: products; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.products (
    id character varying(36) NOT NULL,
    category_id character varying(36) NOT NULL,
    name character varying(150) NOT NULL,
    short_name character varying(20) NOT NULL,
    price_xof integer NOT NULL,
    vat_rate numeric(4,2) NOT NULL,
    track_stock boolean NOT NULL,
    is_custom boolean NOT NULL,
    is_active boolean NOT NULL,
    sort_order integer NOT NULL,
    color character varying(20),
    sku character varying(50),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.products OWNER TO caisse_user;

--
-- Name: purchase_invoices; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.purchase_invoices (
    id character varying(36) NOT NULL,
    invoice_number character varying(100),
    supplier_id character varying(36) NOT NULL,
    received_by_user_id character varying(36) NOT NULL,
    delivery_date date NOT NULL,
    total_amount_xof integer NOT NULL,
    status character varying(20) NOT NULL,
    notes character varying(255),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.purchase_invoices OWNER TO caisse_user;

--
-- Name: purchase_items; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.purchase_items (
    id character varying(36) NOT NULL,
    purchase_invoice_id character varying(36) NOT NULL,
    raw_material_id character varying(36) NOT NULL,
    quantity double precision NOT NULL,
    unit_price_xof integer NOT NULL,
    total_price_xof integer NOT NULL,
    packaging_qty double precision,
    units_per_packaging double precision,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.purchase_items OWNER TO caisse_user;

--
-- Name: purchase_request_lines; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.purchase_request_lines (
    id character varying(36) NOT NULL,
    request_id character varying(36) NOT NULL,
    article_id character varying(36) NOT NULL,
    requested_quantity numeric(12,3) NOT NULL,
    approved_quantity numeric(12,3),
    unit_price_xof numeric(12,2) NOT NULL,
    received_quantity numeric(12,3),
    received_cost_xof integer,
    stock_movement_id character varying(36),
    CONSTRAINT ck_purchase_request_lines_requested_quantity_positive CHECK ((requested_quantity > (0)::numeric))
);


ALTER TABLE public.purchase_request_lines OWNER TO caisse_user;

--
-- Name: purchase_requests; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.purchase_requests (
    id character varying(36) NOT NULL,
    number character varying(16) NOT NULL,
    status character varying(32) DEFAULT 'SUBMITTED'::character varying NOT NULL,
    requested_by_user_id character varying(36) NOT NULL,
    note character varying(255),
    estimated_total_xof integer NOT NULL,
    approved_total_xof integer,
    approved_by_user_id character varying(36),
    approved_at timestamp with time zone,
    disbursed_xof integer,
    disbursed_by_user_id character varying(36),
    disbursed_at timestamp with time zone,
    received_total_xof integer,
    received_by_user_id character varying(36),
    received_at timestamp with time zone,
    supplier character varying(120),
    closed_reason character varying(255),
    closed_by_user_id character varying(36),
    closed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.purchase_requests OWNER TO caisse_user;

--
-- Name: raw_material_movements; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.raw_material_movements (
    id character varying(36) NOT NULL,
    raw_material_id character varying(36) NOT NULL,
    user_id character varying(36) NOT NULL,
    type character varying(30) NOT NULL,
    quantity double precision NOT NULL,
    quantity_after double precision NOT NULL,
    unit_cost_xof integer,
    reason character varying(255) NOT NULL,
    purchase_invoice_id character varying(36),
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.raw_material_movements OWNER TO caisse_user;

--
-- Name: raw_materials; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.raw_materials (
    id character varying(36) NOT NULL,
    name character varying(150) NOT NULL,
    category character varying(50) NOT NULL,
    unit character varying(20) NOT NULL,
    current_stock double precision NOT NULL,
    alert_threshold double precision NOT NULL,
    cost_price_xof integer NOT NULL,
    average_cost_xof integer NOT NULL,
    default_supplier_id character varying(36),
    is_active boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.raw_materials OWNER TO caisse_user;

--
-- Name: restaurant_tables; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.restaurant_tables (
    id character varying(36) NOT NULL,
    label character varying(50) NOT NULL,
    zone character varying(50) NOT NULL,
    seats integer NOT NULL,
    sort_order integer NOT NULL,
    is_active boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.restaurant_tables OWNER TO caisse_user;

--
-- Name: sequence_counters; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.sequence_counters (
    key character varying(80) NOT NULL,
    value integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.sequence_counters OWNER TO caisse_user;

--
-- Name: settings; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.settings (
    key character varying(64) NOT NULL,
    value json,
    updated_by character varying(36),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.settings OWNER TO caisse_user;

--
-- Name: stock_articles; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.stock_articles (
    id character varying(36) NOT NULL,
    name character varying(120) NOT NULL,
    category character varying(32) NOT NULL,
    unit character varying(16) NOT NULL,
    out_mode character varying(32) NOT NULL,
    quantity numeric(12,3) DEFAULT '0'::numeric NOT NULL,
    avg_cost_xof numeric(12,2) DEFAULT '0'::numeric NOT NULL,
    alert_threshold numeric(12,3),
    is_active boolean DEFAULT true NOT NULL,
    note character varying(255),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_stock_articles_avg_cost_positive CHECK ((avg_cost_xof >= (0)::numeric))
);


ALTER TABLE public.stock_articles OWNER TO caisse_user;

--
-- Name: stock_items; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.stock_items (
    id character varying(36) NOT NULL,
    product_id character varying(36) NOT NULL,
    quantity double precision NOT NULL,
    unit character varying(20) NOT NULL,
    alert_threshold double precision NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.stock_items OWNER TO caisse_user;

--
-- Name: stock_movements; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.stock_movements (
    id character varying(36) NOT NULL,
    article_id character varying(36) NOT NULL,
    type character varying(32) NOT NULL,
    quantity numeric(12,3) NOT NULL,
    quantity_after numeric(12,3) NOT NULL,
    unit_cost_xof numeric(12,2) NOT NULL,
    business_date date NOT NULL,
    reference_order_id character varying(36),
    reference_order_item_id character varying(36),
    supplier character varying(120),
    reason character varying(255),
    user_id character varying(36),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.stock_movements OWNER TO caisse_user;

--
-- Name: superettes; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.superettes (
    id integer NOT NULL,
    code character varying(20) NOT NULL,
    nom character varying(150) NOT NULL,
    adresse character varying(255),
    ville character varying(100),
    actif boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.superettes OWNER TO caisse_user;

--
-- Name: superettes_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.superettes_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.superettes_id_seq OWNER TO caisse_user;

--
-- Name: superettes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.superettes_id_seq OWNED BY public.superettes.id;


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.suppliers (
    id character varying(36) NOT NULL,
    name character varying(150) NOT NULL,
    contact_name character varying(100),
    phone character varying(50),
    email character varying(100),
    address character varying(255),
    notes text,
    is_active boolean NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.suppliers OWNER TO caisse_user;

--
-- Name: users; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.users (
    id character varying(36) NOT NULL,
    full_name character varying(100) NOT NULL,
    pin_hash character varying(255) NOT NULL,
    role character varying(20) NOT NULL,
    is_active boolean NOT NULL,
    failed_attempts integer NOT NULL,
    locked_until timestamp with time zone,
    last_login_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.users OWNER TO caisse_user;

--
-- Name: utilisateurs; Type: TABLE; Schema: public; Owner: caisse_user
--

CREATE TABLE public.utilisateurs (
    id integer NOT NULL,
    matricule character varying(30),
    nom_complet character varying(150) NOT NULL,
    email character varying(150),
    telephone character varying(30),
    mot_de_passe_hash text NOT NULL,
    role public.role_utilisateur NOT NULL,
    superette_id integer,
    actif boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.utilisateurs OWNER TO caisse_user;

--
-- Name: utilisateurs_id_seq; Type: SEQUENCE; Schema: public; Owner: caisse_user
--

CREATE SEQUENCE public.utilisateurs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.utilisateurs_id_seq OWNER TO caisse_user;

--
-- Name: utilisateurs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: caisse_user
--

ALTER SEQUENCE public.utilisateurs_id_seq OWNED BY public.utilisateurs.id;


--
-- Name: vue_bilan_mensuel; Type: VIEW; Schema: public; Owner: caisse_user
--

CREATE VIEW public.vue_bilan_mensuel AS
 SELECT s.nom AS superette,
    (date_trunc('month'::text, (cj.date_operation)::timestamp with time zone))::date AS mois,
    sum(cj.total_encaissements) AS total_entrees,
    sum(cj.total_decaissements) AS total_sorties,
    min(cj.solde_veille) AS solde_debut_mois,
    (array_agg(cj.solde_theorique ORDER BY cj.date_operation DESC))[1] AS solde_fin_mois
   FROM (public.caisse_journees cj
     JOIN public.superettes s ON ((s.id = cj.superette_id)))
  GROUP BY s.nom, cj.superette_id, ((date_trunc('month'::text, (cj.date_operation)::timestamp with time zone))::date);


ALTER TABLE public.vue_bilan_mensuel OWNER TO caisse_user;

--
-- Name: vue_billetage_detail; Type: VIEW; Schema: public; Owner: caisse_user
--

CREATE VIEW public.vue_billetage_detail AS
 SELECT bc.caisse_journee_id,
    d.valeur,
    d.type,
    bc.nombre,
    ((bc.nombre)::numeric * d.valeur) AS montant
   FROM (public.billetage_comptage bc
     JOIN public.denominations d ON ((d.id = bc.denomination_id)));


ALTER TABLE public.vue_billetage_detail OWNER TO caisse_user;

--
-- Name: vue_evolution_tresorerie; Type: VIEW; Schema: public; Owner: caisse_user
--

CREATE VIEW public.vue_evolution_tresorerie AS
 SELECT s.nom AS superette,
    ct.date_mouvement,
    ct.type_mouvement,
    ct.libelle,
    ct.montant,
    ct.solde_avant,
    ct.solde_apres
   FROM (public.cahier_tresorerie ct
     JOIN public.superettes s ON ((s.id = ct.superette_id)))
  ORDER BY s.nom, ct.date_mouvement, ct.id;


ALTER TABLE public.vue_evolution_tresorerie OWNER TO caisse_user;

--
-- Name: vue_solde_journee; Type: VIEW; Schema: public; Owner: caisse_user
--

CREATE VIEW public.vue_solde_journee AS
 SELECT cj.id,
    s.nom AS superette,
    cj.date_operation,
    cj.solde_veille,
    cj.total_encaissements,
    cj.total_decaissements,
    cj.solde_theorique,
    cj.total_billetage,
    cj.billetage_effectue,
    cj.ecart,
    cj.statut
   FROM (public.caisse_journees cj
     JOIN public.superettes s ON ((s.id = cj.superette_id)));


ALTER TABLE public.vue_solde_journee OWNER TO caisse_user;

--
-- Name: audit_log id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.audit_log ALTER COLUMN id SET DEFAULT nextval('public.audit_log_id_seq'::regclass);


--
-- Name: autorisations_depense id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.autorisations_depense ALTER COLUMN id SET DEFAULT nextval('public.autorisations_depense_id_seq'::regclass);


--
-- Name: billetage_comptage id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.billetage_comptage ALTER COLUMN id SET DEFAULT nextval('public.billetage_comptage_id_seq'::regclass);


--
-- Name: cahier_tresorerie id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cahier_tresorerie ALTER COLUMN id SET DEFAULT nextval('public.cahier_tresorerie_id_seq'::regclass);


--
-- Name: caisse_journees id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.caisse_journees ALTER COLUMN id SET DEFAULT nextval('public.caisse_journees_id_seq'::regclass);


--
-- Name: categories_depense id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.categories_depense ALTER COLUMN id SET DEFAULT nextval('public.categories_depense_id_seq'::regclass);


--
-- Name: denominations id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.denominations ALTER COLUMN id SET DEFAULT nextval('public.denominations_id_seq'::regclass);


--
-- Name: fournisseurs id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.fournisseurs ALTER COLUMN id SET DEFAULT nextval('public.fournisseurs_id_seq'::regclass);


--
-- Name: justificatifs id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.justificatifs ALTER COLUMN id SET DEFAULT nextval('public.justificatifs_id_seq'::regclass);


--
-- Name: operations_decaissement id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_decaissement ALTER COLUMN id SET DEFAULT nextval('public.operations_decaissement_id_seq'::regclass);


--
-- Name: operations_encaissement id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_encaissement ALTER COLUMN id SET DEFAULT nextval('public.operations_encaissement_id_seq'::regclass);


--
-- Name: superettes id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.superettes ALTER COLUMN id SET DEFAULT nextval('public.superettes_id_seq'::regclass);


--
-- Name: utilisateurs id; Type: DEFAULT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.utilisateurs ALTER COLUMN id SET DEFAULT nextval('public.utilisateurs_id_seq'::regclass);


--
-- Data for Name: alembic_version; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.alembic_version (version_num) FROM stdin;
018_fne_point_of_sale_setting
\.


--
-- Data for Name: audit_log; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.audit_log (id, utilisateur_id, table_cible, ligne_id, action, ancienne_valeur, nouvelle_valeur, date_action) FROM stdin;
257	433	caisse_journees	370	INSERT	null	{"statut": "ouverte", "solde_veille": 296750.0, "superette_id": 377, "date_operation": "2026-09-04"}	2026-09-04 09:20:39.881153+00
259	433	operations_encaissement	184	INSERT	null	{"type": "vente", "libelle": "Vente du jour", "montant": 520000.0, "caisse_journee_id": 370}	2026-09-04 14:40:33.718073+00
260	433	operations_decaissement	129	INSERT	null	{"objet": "SOLDE FACTURE", "montant": 39600.0, "n_facture": null, "designation": "SABIMEX", "n_piece_caisse": null, "caisse_journee_id": 370}	2026-09-04 14:42:20.415627+00
2435	433	caisse_journees	1080	UPDATE	{"statut": "ouverte"}	{"ecart": 0.0, "statut": "cloturee", "solde_theorique": 491050.0, "total_billetage": 491050.0, "commentaire_ecart": null, "total_decaissements": 848950.0, "total_encaissements": 555000.0}	2026-09-07 13:52:08.135916+00
2439	433	caisse_journees	1136	INSERT	null	{"statut": "ouverte", "solde_veille": 491050.0, "superette_id": 377, "date_operation": "2026-09-08"}	2026-09-08 10:30:01.384427+00
2443	433	justificatifs	89	DOWNLOAD	null	{"nom_fichier": "Journal_Tresorerie_2026-09-07.pdf"}	2026-09-08 11:35:09.831247+00
7	433	caisse_journees	270	INSERT	\N	{"statut": "ouverte", "solde_veille": 0.0, "superette_id": 377, "date_operation": "2026-09-02"}	2026-09-02 11:15:59.975372+00
8	432	caisse_journees	270	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "solde_theorique": 323000.0, "total_billetage": 323000.0}	2026-09-02 15:59:34.852903+00
9	433	caisse_journees	271	INSERT	\N	{"statut": "ouverte", "solde_veille": 323000.0, "superette_id": 377, "date_operation": "2026-09-03"}	2026-09-03 07:43:47.746896+00
10	433	operations_encaissement	131	INSERT	\N	{"type": "vente", "libelle": "Vente du jour", "montant": 323000.0, "caisse_journee_id": 270}	2026-09-02 11:44:51.463878+00
11	433	operations_encaissement	132	INSERT	\N	{"type": "approvisionnement", "libelle": "RETOUR MONNAIE / ACHAT MARCHE", "montant": 3250.0, "caisse_journee_id": 271}	2026-09-03 09:08:55.750291+00
12	433	operations_encaissement	133	INSERT	\N	{"type": "vente", "libelle": "Vente du Rose Monde", "montant": 120000.0, "caisse_journee_id": 271}	2026-09-03 09:11:51.162986+00
13	433	operations_decaissement	85	INSERT	\N	{"objet": "PANZANI OUEST AFRIC", "montant": 9500.0, "n_facture": "0015144", "designation": "ACHAT DE SPAGUETTI PANZANI", "n_piece_caisse": "213254", "caisse_journee_id": 271}	2026-09-03 07:51:28.861992+00
14	433	operations_decaissement	86	INSERT	\N	{"objet": "ACHAT SENTINELLE", "montant": 50000.0, "n_facture": "0456178", "designation": "ACHAT SENTINELLE", "n_piece_caisse": "PC-001", "caisse_journee_id": 271}	2026-09-03 09:18:42.663913+00
15	433	operations_decaissement	87	INSERT	\N	{"objet": "ACHAT YAOURT VIGORT", "montant": 20000.0, "n_facture": "0471602", "designation": "ACHAT YAOURT VIGORT", "n_piece_caisse": "00124", "caisse_journee_id": 271}	2026-09-03 10:05:14.89875+00
2448	433	autorisations_depense	264	INSERT	null	{"objet": "REGLEMENT PARTIEL DU SALAIRE DU PERSONNEL", "statut": "en_attente", "montant": 220000.0, "demandeur": "REGLEMENT PARTIEL DU PERSONNEL", "caisse_journee_id": 1136}	2026-09-08 14:17:32.19444+00
2451	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-08 14:18:56.757428+00
2452	433	operations_decaissement	401	INSERT	null	{"objet": "REGLEMENT PARTIEL DU PERSONNEL", "montant": 220000.0, "n_facture": null, "designation": "REGLEMENT PARTIEL DU PERSONNEL", "n_piece_caisse": "254365", "caisse_journee_id": 1136}	2026-09-08 14:20:16.576236+00
2460	433	operations_decaissement	406	INSERT	null	{"objet": "SALAMI NASSREDINE ALI", "montant": 22000.0, "n_facture": "123456", "designation": "ACHAT HUILE D'OLIVE", "n_piece_caisse": "654123", "caisse_journee_id": 1136}	2026-09-08 14:26:58.375047+00
2462	433	justificatifs	92	DOWNLOAD	null	{"nom_fichier": "Bilan_Mensuel_2026-09-3.pdf"}	2026-09-08 14:28:12.182883+00
2768	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-10 11:30:54.59496+00
3342	2340	utilisateurs	2340	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST002"}	2026-09-18 17:22:15.640619+00
3201	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-11 15:19:10.172174+00
2002	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-07 10:02:22.126983+00
3478	2340	utilisateurs	2340	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST002"}	2026-09-18 17:27:26.926569+00
2276	433	operations_decaissement	374	INSERT	null	{"objet": "ACHAT EAU AWA", "montant": 89000.0, "n_facture": "3215468", "designation": "Achat eau awa à Solibra", "n_piece_caisse": "69857", "caisse_journee_id": 1080}	2026-09-07 10:47:10.921493+00
3479	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-28 10:31:24.054742+00
2293	433	justificatifs	88	DOWNLOAD	null	{"nom_fichier": "logo-dark.png"}	2026-09-07 11:24:47.656381+00
2303	433	operations_decaissement	384	INSERT	null	{"objet": "ACHAT DE RIZ", "montant": 480000.0, "n_facture": "234040", "designation": "ACHAT DE RIZ", "n_piece_caisse": "234047", "caisse_journee_id": 1080}	2026-09-07 11:50:56.018075+00
138	433	operations_decaissement	109	INSERT	null	{"objet": "ACHAT MARCHE", "montant": 65000.0, "n_facture": null, "designation": "ACHAT MARCHE", "n_piece_caisse": "P-008", "caisse_journee_id": 271}	2026-09-03 15:26:10.458469+00
140	433	billetage_comptage	271	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 271}	2026-09-03 15:33:21.061298+00
375	433	autorisations_depense	62	INSERT	null	{"objet": "ACHAT EAU AWA", "statut": "en_attente", "montant": 153200.0, "demandeur": "SOLIBRA", "caisse_journee_id": 370}	2026-09-04 15:23:12.915673+00
377	433	operations_decaissement	147	INSERT	null	{"objet": "ACHAT EAU AWA", "montant": 153200.0, "n_facture": "589647", "designation": "ACHAT EAU AWA", "n_piece_caisse": "P-008", "caisse_journee_id": 370}	2026-09-04 15:25:59.027809+00
378	433	operations_decaissement	148	INSERT	null	{"objet": "COMPLEMENT SIPROCHIME", "montant": 60000.0, "n_facture": "A758659", "designation": "COMPLEMENT SIPROCHIME", "n_piece_caisse": "9626229", "caisse_journee_id": 370}	2026-09-04 15:28:32.541293+00
456	433	billetage_comptage	370	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 370}	2026-09-04 16:09:48.362939+00
458	433	caisse_journees	370	UPDATE	{"statut": "ouverte"}	{"ecart": 0.0, "statut": "cloturee", "solde_theorique": 500000.0, "total_billetage": 500000.0, "commentaire_ecart": null, "total_decaissements": 316750.0, "total_encaissements": 520000.0}	2026-09-04 16:10:56.815109+00
4112	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-09-28 11:23:16.607511+00
4121	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-09-28 11:28:33.267635+00
4262	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-09-28 11:40:07.252095+00
258	433	operations_decaissement	128	INSERT	null	{"objet": "ACPTE ACHAT DE YAOURT", "montant": 59000.0, "n_facture": "23125", "designation": "ACPTE ACHAT DE YAOURT", "n_piece_caisse": "36524", "caisse_journee_id": 370}	2026-09-04 09:53:10.532644+00
2436	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-07 13:52:38.596799+00
2440	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-08 10:30:27.759921+00
2442	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-08 11:32:39.341479+00
2445	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-08 14:09:35.16+00
2454	433	operations_decaissement	403	INSERT	null	{"objet": "ACHAT SAUCISSON N'ZIANOUAN", "montant": 42200.0, "n_facture": "3596", "designation": "ACHAT SAUCISSON N'ZIANOUAN", "n_piece_caisse": "9854", "caisse_journee_id": 1136}	2026-09-08 14:23:04.885524+00
2458	433	operations_decaissement	405	INSERT	null	{"objet": "ACHAT TEA", "montant": 11500.0, "n_facture": "3652", "designation": "ACHAT TEA", "n_piece_caisse": "9874", "caisse_journee_id": 1136}	2026-09-08 14:25:19.068342+00
2461	433	justificatifs	95	DOWNLOAD	null	{"nom_fichier": "logo-dark.png"}	2026-09-08 14:28:05.229631+00
2769	433	caisse_journees	1261	INSERT	null	{"statut": "ouverte", "solde_veille": 774750.0, "superette_id": 377, "date_operation": "2026-09-10"}	2026-09-10 13:55:51.58764+00
3480	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-28 10:35:31.349519+00
2278	433	operations_decaissement	375	INSERT	null	{"objet": "TRANSPORT DOSSO", "montant": 20000.0, "n_facture": null, "designation": "Transport Achat Mat", "n_piece_caisse": "231564", "caisse_journee_id": 1080}	2026-09-07 10:54:48.114524+00
3202	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-11 21:02:22.284967+00
2919	433	operations_decaissement	454	INSERT	null	{"objet": "VERSEMENT ECOBANK", "montant": 65000.0, "n_facture": null, "designation": "Versement", "n_piece_caisse": "ver12435", "caisse_journee_id": 1261}	2026-09-10 14:38:47.621613+00
2920	433	operations_decaissement	455	INSERT	null	{"objet": "ACPTE ACHAT PETIT POIDS TALPE", "montant": 55000.0, "n_facture": "321456", "designation": "ACPTE ACHAT PETIT POIDS TALPE", "n_piece_caisse": "98745", "caisse_journee_id": 1261}	2026-09-10 14:39:59.610378+00
2923	433	justificatifs	105	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 456}	2026-09-10 14:44:29.011046+00
55	433	operations_decaissement	94	INSERT	null	{"objet": "TRANSPORT", "montant": 5000.0, "n_facture": null, "designation": "TRANSPORT", "n_piece_caisse": "PC-005", "caisse_journee_id": 271}	2026-09-03 11:38:14.043287+00
2288	432	autorisations_depense	247	UPDATE	{"statut": "en_attente"}	{"objet": "Achat de produit laitier", "statut": "approuvee", "montant": 256000.0}	2026-09-07 11:22:58.194041+00
2295	433	operations_decaissement	381	INSERT	null	{"objet": "Entretient bureau", "montant": 1950.0, "n_facture": null, "designation": "ACHAT POUR BUREAUX", "n_piece_caisse": "5987", "caisse_journee_id": 1080}	2026-09-07 11:40:31.414384+00
2298	433	operations_encaissement	398	INSERT	null	{"type": "vente", "libelle": "Vente du jour", "montant": 520000.0, "caisse_journee_id": 1080}	2026-09-07 11:46:09.615297+00
2305	433	billetage_comptage	1080	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 1080}	2026-09-07 12:00:07.201795+00
4113	432	utilisateurs	2419	UPDATE	null	{"role": "responsable", "actif": true, "matricule": "RESP001", "nom_complet": "Mamadou Koné (Resp. Sorbonne)"}	2026-09-28 11:24:03.523642+00
4120	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-28 11:28:18.468646+00
4404	432	utilisateurs	316	UPDATE	null	{"role": "caissier", "actif": true, "matricule": "CAIS01", "nom_complet": "Kouamé Aya"}	2026-09-28 11:56:11.785567+00
376	432	autorisations_depense	62	UPDATE	{"statut": "en_attente"}	{"objet": "ACHAT EAU AWA", "statut": "approuvee", "montant": 153200.0}	2026-09-04 15:24:17.587213+00
379	433	operations_decaissement	149	INSERT	null	{"objet": "TRANSPORT JULIE", "montant": 4950.0, "n_facture": null, "designation": "Transport achat", "n_piece_caisse": "899559", "caisse_journee_id": 370}	2026-09-04 15:33:01.820244+00
139	433	billetage_comptage	271	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 271}	2026-09-03 15:33:17.001468+00
141	433	caisse_journees	271	UPDATE	{"statut": "ouverte"}	{"ecart": 0.0, "statut": "cloturee", "solde_theorique": 296750.0, "total_billetage": 296750.0, "commentaire_ecart": null, "total_decaissements": 149500.0, "total_encaissements": 123250.0}	2026-09-03 15:34:12.644298+00
142	432	caisse_journees	271	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "commentaire_validation": null}	2026-09-03 15:35:36.275058+00
457	433	billetage_comptage	370	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 370}	2026-09-04 16:09:51.178079+00
459	432	caisse_journees	370	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "commentaire_validation": null}	2026-09-04 16:12:13.095587+00
460	433	caisse_journees	451	INSERT	null	{"statut": "ouverte", "solde_veille": 500000.0, "superette_id": 377, "date_operation": "2026-09-05"}	2026-09-05 17:54:22.175393+00
461	433	operations_encaissement	223	INSERT	null	{"type": "vente", "libelle": "Vente du jour", "montant": 350000.0, "caisse_journee_id": 451}	2026-09-05 17:56:23.716112+00
462	433	operations_decaissement	162	INSERT	null	{"objet": "ACHAT DE SPAGUETTI PANZANI", "montant": 65000.0, "n_facture": "5896284", "designation": "ACHAT DE SPAGUETTI PANZANI", "n_piece_caisse": "875", "caisse_journee_id": 451}	2026-09-05 17:59:56.054687+00
463	433	autorisations_depense	69	INSERT	null	{"objet": "Eau Awa", "statut": "en_attente", "montant": 135000.0, "demandeur": "SOLIBRA", "caisse_journee_id": 451}	2026-09-05 18:01:44.789754+00
464	433	billetage_comptage	451	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 451}	2026-09-05 18:10:11.557964+00
465	432	autorisations_depense	69	UPDATE	{"statut": "en_attente"}	{"objet": "Eau Awa", "statut": "approuvee", "montant": 135000.0}	2026-09-05 18:31:05.890175+00
4701	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-07 10:22:34.525185+00
4706	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-07 10:25:14.792257+00
2521	433	billetage_comptage	1136	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 1136}	2026-09-08 15:11:49.954638+00
4708	433	autorisations_depense	513	INSERT	null	{"objet": "ACHAT DE RIZ", "statut": "en_attente", "montant": 435000.0, "demandeur": "SYLLA FRERE", "caisse_journee_id": 1949}	2026-10-07 10:38:57.661773+00
466	433	caisse_journees	451	UPDATE	{"statut": "ouverte"}	{"ecart": 0.0, "statut": "cloturee", "solde_theorique": 785000.0, "total_billetage": 785000.0, "commentaire_ecart": null, "total_decaissements": 65000.0, "total_encaissements": 350000.0}	2026-09-05 18:43:28.291021+00
2437	432	caisse_journees	1080	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "commentaire_validation": null}	2026-09-07 13:53:27.309766+00
2441	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-08 11:26:10.14583+00
2446	433	operations_decaissement	400	INSERT	null	{"objet": "ACHAT YAOUT", "montant": 59950.0, "n_facture": "64854", "designation": "ACHAT YAOUT", "n_piece_caisse": "36195", "caisse_journee_id": 1136}	2026-09-08 14:13:26.413333+00
2449	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-08 14:18:07.671676+00
2450	432	autorisations_depense	264	UPDATE	{"statut": "en_attente"}	{"objet": "REGLEMENT PARTIEL DU SALAIRE DU PERSONNEL", "statut": "approuvee", "montant": 220000.0}	2026-09-08 14:18:42.020545+00
2453	433	operations_decaissement	402	INSERT	null	{"objet": "PARTICIPATION N'ZIANOUAN ACHAT BATTERIE", "montant": 14000.0, "n_facture": null, "designation": "PARTICIPATION N'ZIANOUAN ACHAT BATTERIE", "n_piece_caisse": "632145", "caisse_journee_id": 1136}	2026-09-08 14:21:04.79128+00
2457	433	justificatifs	94	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 404}	2026-09-08 14:23:56.148752+00
2463	433	operations_encaissement	409	INSERT	null	{"type": "vente", "libelle": "Vente du jour", "montant": 755000.0, "caisse_journee_id": 1136}	2026-09-08 14:29:59.571726+00
4114	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-09-28 11:24:20.711858+00
3203	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-11 21:08:36.132011+00
2921	433	justificatifs	104	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 455}	2026-09-10 14:39:59.760715+00
2924	433	operations_decaissement	457	INSERT	null	{"objet": "ACHAT CARBURANT", "montant": 32000.0, "n_facture": null, "designation": "Plein MASSA", "n_piece_caisse": "98653", "caisse_journee_id": 1261}	2026-09-10 14:46:06.724394+00
2929	432	caisse_journees	1261	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "commentaire_validation": null}	2026-09-10 14:56:50.32068+00
4116	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-09-28 11:25:52.663875+00
2286	433	autorisations_depense	247	INSERT	null	{"objet": "Achat de produit laitier", "statut": "en_attente", "montant": 256000.0, "demandeur": "Fournisseur EUROLAIT", "caisse_journee_id": 1080}	2026-09-07 11:21:33.630069+00
2291	433	justificatifs	88	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 380}	2026-09-07 11:24:33.620136+00
2299	433	autorisations_depense	248	INSERT	null	{"objet": "ACHAT DE RIZ", "statut": "en_attente", "montant": 480000.0, "demandeur": "SYLLA FRERE", "caisse_journee_id": 1080}	2026-09-07 11:47:07.638693+00
2300	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-07 11:48:32.410972+00
2301	432	autorisations_depense	248	UPDATE	{"statut": "en_attente"}	{"objet": "ACHAT DE RIZ", "statut": "approuvee", "montant": 480000.0}	2026-09-07 11:49:12.729354+00
2304	433	justificatifs	89	INSERT	null	{"nom_fichier": "Journal_Tresorerie_2026-09-07.pdf", "type_document": "facture", "operation_decaissement_id": 384}	2026-09-07 11:50:56.179984+00
2307	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-07 12:05:18.644008+00
4118	433	caisse_journees	1752	INSERT	null	{"statut": "ouverte", "solde_veille": 595250.0, "superette_id": 377, "date_operation": "2026-09-28"}	2026-09-28 11:26:27.850903+00
4257	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-09-28 11:33:52.176007+00
4258	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-28 11:34:53.69669+00
4264	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-09-28 11:40:37.797464+00
4267	433	justificatifs	126	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 607}	2026-09-28 11:42:02.844736+00
4405	432	utilisateurs	316	UPDATE	null	{"role": "caissier", "actif": false, "matricule": "CAIS01", "nom_complet": "Kouamé Aya"}	2026-09-28 11:56:18.392846+00
4407	433	operations_encaissement	551	INSERT	null	{"type": "approvisionnement", "libelle": "RETOUR MONNAIE / ACHAT MARCHE", "montant": 75000.0, "caisse_journee_id": 1752}	2026-09-28 12:01:59.419848+00
4702	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-10-07 10:23:48.594046+00
4709	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-10-07 10:39:06.14918+00
4543	433	operations_encaissement	562	INSERT	null	{"type": "vente", "libelle": "Vente du jour", "montant": 650000.0, "caisse_journee_id": 1752}	2026-09-28 12:09:25.266434+00
4548	2419	caisse_journees	1752	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "commentaire_validation": null}	2026-09-28 12:15:06.801707+00
2511	433	operations_decaissement	414	INSERT	null	{"objet": "ACPTE ACHAT PETIT POIDS TALPE", "montant": 50000.0, "n_facture": "12369", "designation": "ACPTE ACHAT PETIT POIDS TALPE", "n_piece_caisse": "9632", "caisse_journee_id": 1136}	2026-09-08 14:54:47.035665+00
2516	433	operations_encaissement	412	INSERT	null	{"type": "vente", "libelle": "Vente du jour", "montant": 150000.0, "caisse_journee_id": 1136}	2026-09-08 15:01:25.272223+00
2517	433	operations_decaissement	417	INSERT	null	{"objet": "COMPLEMENT ACHAT MACHE", "montant": 51000.0, "n_facture": null, "designation": "COMPLEMENT ACHAT MACHE", "n_piece_caisse": "32459", "caisse_journee_id": 1136}	2026-09-08 15:02:37.459379+00
2519	433	operations_decaissement	418	INSERT	null	{"objet": "ACPTE PROSUMA", "montant": 63850.0, "n_facture": "9874", "designation": "ACPTE PROSUMA", "n_piece_caisse": "PC-002", "caisse_journee_id": 1136}	2026-09-08 15:08:24.134451+00
4549	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-09-28 12:15:25.092202+00
4553	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-03 15:02:36.079142+00
467	432	caisse_journees	451	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "commentaire_validation": null}	2026-09-05 18:44:40.402089+00
2438	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-07 15:26:49.038283+00
2444	433	justificatifs	87	DOWNLOAD	null	{"nom_fichier": "Bilan_Mensuel_2026-09-1.pdf"}	2026-09-08 11:35:31.816385+00
2447	433	justificatifs	92	INSERT	null	{"nom_fichier": "Bilan_Mensuel_2026-09-3.pdf", "type_document": "facture", "operation_decaissement_id": 400}	2026-09-08 14:13:26.730808+00
2455	433	justificatifs	93	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 403}	2026-09-08 14:23:05.119098+00
2456	433	operations_decaissement	404	INSERT	null	{"objet": "ACHAT SAUCISSON", "montant": 10000.0, "n_facture": "78459", "designation": "ACHAT SAUCISSON", "n_piece_caisse": "96321", "caisse_journee_id": 1136}	2026-09-08 14:23:56.023187+00
2459	433	justificatifs	95	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 405}	2026-09-08 14:25:19.179757+00
4115	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-28 11:25:05.690389+00
4259	433	autorisations_depense	467	INSERT	null	{"objet": "ACHAT DE RIZ", "statut": "en_attente", "montant": 450000.0, "demandeur": "SYLLA FRERE", "caisse_journee_id": 1752}	2026-09-28 11:35:38.735618+00
3204	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-14 20:23:06.047651+00
2922	433	operations_decaissement	456	INSERT	null	{"objet": "SOLDE FACTURE (CHU)", "montant": 27500.0, "n_facture": "321457", "designation": "OISA", "n_piece_caisse": "PC-0088", "caisse_journee_id": 1261}	2026-09-10 14:44:28.830534+00
2925	433	justificatifs	106	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 457}	2026-09-10 14:46:06.830314+00
2926	433	billetage_comptage	1261	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 1261}	2026-09-10 14:55:25.699867+00
2275	433	caisse_journees	1080	INSERT	null	{"statut": "ouverte", "solde_veille": 785000.0, "superette_id": 377, "date_operation": "2026-09-07"}	2026-09-07 10:44:33.328882+00
2277	433	justificatifs	87	INSERT	null	{"nom_fichier": "Bilan_Mensuel_2026-09-1.pdf", "type_document": "facture", "operation_decaissement_id": 374}	2026-09-07 10:47:11.072534+00
3205	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-14 20:23:12.243348+00
2287	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-07 11:21:50.331955+00
2289	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-07 11:23:24.32978+00
2290	433	operations_decaissement	380	INSERT	null	{"objet": "Achat de produit laitier", "montant": 256000.0, "n_facture": "213596", "designation": "Achat de produit laitier", "n_piece_caisse": "87456", "caisse_journee_id": 1080}	2026-09-07 11:24:33.4192+00
2292	433	justificatifs	87	DOWNLOAD	null	{"nom_fichier": "Bilan_Mensuel_2026-09-1.pdf"}	2026-09-07 11:24:38.107327+00
2294	433	operations_encaissement	397	INSERT	null	{"type": "approvisionnement", "libelle": "RETOUR MONNAIE / ACHAT MARCHE", "montant": 35000.0, "caisse_journee_id": 1080}	2026-09-07 11:30:35.969608+00
2296	433	operations_decaissement	382	INSERT	null	{"objet": "ACHAT BOSS", "montant": 1500.0, "n_facture": null, "designation": "ACHAT BOSS", "n_piece_caisse": "22548", "caisse_journee_id": 1080}	2026-09-07 11:41:54.097947+00
2297	433	operations_decaissement	383	INSERT	null	{"objet": "GONFLET PNEU", "montant": 500.0, "n_facture": null, "designation": "MASSA", "n_piece_caisse": "547896", "caisse_journee_id": 1080}	2026-09-07 11:43:02.607992+00
2302	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-07 11:49:37.560855+00
2306	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-07 12:00:54.985718+00
3206	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-14 20:24:48.606212+00
4266	433	operations_decaissement	607	INSERT	null	{"objet": "ACHAT DE RIZ", "montant": 450000.0, "n_facture": "321456987", "designation": "Achat de riz", "n_piece_caisse": null, "caisse_journee_id": 1752}	2026-09-28 11:42:02.775461+00
4268	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-09-28 11:43:06.914075+00
4406	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-28 12:01:02.584963+00
4703	433	caisse_journees	1949	INSERT	null	{"statut": "ouverte", "solde_veille": 870250.0, "superette_id": 377, "date_operation": "2026-10-07"}	2026-10-07 10:23:55.279968+00
2510	433	justificatifs	96	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 406}	2026-09-08 14:46:33.484212+00
2512	433	justificatifs	97	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 414}	2026-09-08 14:54:47.175655+00
2513	433	operations_decaissement	415	INSERT	null	{"objet": "TRANSPORT MARCHANDISE", "montant": 12500.0, "n_facture": null, "designation": "TRANSPORT MARCHANDISE pour N'ZIANOUA", "n_piece_caisse": "213587", "caisse_journee_id": 1136}	2026-09-08 14:56:26.478492+00
2514	433	operations_decaissement	416	INSERT	null	{"objet": "ACHAT D'EAU CELESTE", "montant": 44300.0, "n_facture": "789654", "designation": "ACHAT D'EAU CELESTE", "n_piece_caisse": "3698", "caisse_journee_id": 1136}	2026-09-08 15:00:08.182118+00
2515	433	justificatifs	98	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 416}	2026-09-08 15:00:08.314606+00
2518	433	billetage_comptage	1136	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 1136}	2026-09-08 15:07:02.105855+00
2520	433	justificatifs	99	INSERT	null	{"nom_fichier": "logo-dark.png", "type_document": "facture", "operation_decaissement_id": 418}	2026-09-08 15:08:24.316314+00
2522	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-08 15:11:58.788252+00
2523	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-08 15:13:13.465544+00
2524	433	operations_decaissement	419	INSERT	null	{"objet": "ENTRETIENT", "montant": 20000.0, "n_facture": null, "designation": "ENTRETIENT BUREAU BOSS", "n_piece_caisse": "87965", "caisse_journee_id": 1136}	2026-09-08 15:17:08.089021+00
4544	433	billetage_comptage	1752	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 1752}	2026-09-28 12:13:31.058615+00
2525	433	billetage_comptage	1136	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 1136}	2026-09-08 15:18:33.126426+00
2527	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-08 15:19:34.351283+00
2528	432	caisse_journees	1136	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "commentaire_validation": null}	2026-09-08 15:38:00.785587+00
4117	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-28 11:26:23.871885+00
4119	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-09-28 11:27:22.25539+00
4260	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-09-28 11:35:50.400442+00
2927	433	caisse_journees	1261	UPDATE	{"statut": "ouverte"}	{"ecart": 0.0, "statut": "cloturee", "solde_theorique": 595250.0, "total_billetage": 595250.0, "commentaire_ecart": null, "total_decaissements": 179500.0, "total_encaissements": 0.0}	2026-09-10 14:55:37.118724+00
2928	432	utilisateurs	432	LOGIN	null	{"role": "gestionnaire", "matricule": "GEST001"}	2026-09-10 14:55:58.2917+00
4265	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-28 11:40:59.711897+00
4704	433	operations_decaissement	653	INSERT	null	{"objet": "Achat poulet", "montant": 45000.0, "n_facture": "865479", "designation": "Achat poulet", "n_piece_caisse": "CAISSE PRINCIPALE", "caisse_journee_id": 1949}	2026-10-07 10:24:59.860325+00
4707	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-10-07 10:37:18.49889+00
4545	433	billetage_comptage	1752	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 1752}	2026-09-28 12:13:46.02778+00
4550	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-03 15:00:17.638681+00
4551	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-10-03 15:00:33.726186+00
4554	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-10-03 15:12:59.962647+00
4555	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-10-07 10:10:10.816536+00
2526	433	caisse_journees	1136	UPDATE	{"statut": "ouverte"}	{"ecart": 0.0, "statut": "cloturee", "solde_theorique": 774750.0, "total_billetage": 774750.0, "commentaire_ecart": null, "total_decaissements": 621300.0, "total_encaissements": 905000.0}	2026-09-08 15:19:19.53402+00
4261	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-09-28 11:36:04.534844+00
4263	2419	autorisations_depense	467	UPDATE	{"statut": "en_attente"}	{"objet": "ACHAT DE RIZ", "statut": "approuvee", "montant": 450000.0}	2026-09-28 11:40:27.768052+00
4705	433	justificatifs	133	INSERT	null	{"nom_fichier": "WhatsApp Image 2026-10-06 at 11.54.58.jpeg", "type_document": "facture", "operation_decaissement_id": 653}	2026-10-07 10:24:59.929849+00
4710	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-07 10:41:34.87045+00
2930	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-09-11 14:35:44.230414+00
4546	433	caisse_journees	1752	UPDATE	{"statut": "ouverte"}	{"ecart": 0.0, "statut": "cloturee", "solde_theorique": 870250.0, "total_billetage": 870250.0, "commentaire_ecart": null, "total_decaissements": 450000.0, "total_encaissements": 725000.0}	2026-09-28 12:13:57.175747+00
4547	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-09-28 12:14:09.160304+00
4552	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-10-03 15:02:23.649309+00
4556	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-07 10:10:35.684715+00
4557	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-10-07 10:11:39.626343+00
4784	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-10-07 10:55:51.328997+00
4785	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-07 10:56:17.37065+00
4786	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-10-07 10:56:30.693123+00
4787	432	autorisations_depense	513	UPDATE	{"statut": "en_attente"}	{"objet": "ACHAT DE RIZ", "statut": "approuvee", "montant": 435000.0}	2026-10-07 10:56:53.676126+00
4788	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-10-07 10:57:34.167681+00
4789	433	operations_decaissement	654	INSERT	null	{"objet": "ACHAT DE RIZ", "montant": 435000.0, "n_facture": "145698", "designation": "Achat de riz", "n_piece_caisse": "CAISSE PRINCIPALE", "caisse_journee_id": 1949}	2026-10-07 10:58:43.711854+00
4790	433	justificatifs	134	INSERT	null	{"nom_fichier": "WhatsApp Image 2026-10-06 at 11.54.58.jpeg", "type_document": "facture", "operation_decaissement_id": 654}	2026-10-07 10:58:43.777787+00
4791	433	justificatifs	133	DOWNLOAD	null	{"nom_fichier": "WhatsApp Image 2026-10-06 at 11.54.58.jpeg"}	2026-10-07 11:55:18.634436+00
4792	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-10-07 12:06:02.385194+00
4793	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-10-07 12:07:10.472214+00
4794	433	operations_encaissement	576	INSERT	null	{"type": "approvisionnement", "libelle": "RETOUR MONNAIE / ACHAT MARCHE", "montant": 15000.0, "caisse_journee_id": 1949}	2026-10-07 12:23:30.797225+00
4795	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-07 12:24:44.837722+00
4796	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-10-07 14:48:10.374365+00
4797	433	billetage_comptage	1949	UPDATE	null	{"nombre_lignes": 12, "caisse_journee_id": 1949}	2026-10-07 15:16:12.915685+00
4798	433	caisse_journees	1949	UPDATE	{"statut": "ouverte"}	{"ecart": -5250.0, "statut": "cloturee", "solde_theorique": 405250.0, "total_billetage": 400000.0, "commentaire_ecart": "Erreur de rendu monnaie en caisse", "total_decaissements": 480000.0, "total_encaissements": 15000.0}	2026-10-07 15:16:41.435905+00
4799	2419	utilisateurs	2419	LOGIN	null	{"role": "responsable", "matricule": "RESP001"}	2026-10-07 15:17:11.018998+00
4800	2419	caisse_journees	1949	UPDATE	{"statut": "cloturee"}	{"statut": "validee", "commentaire_validation": null}	2026-10-07 15:17:46.925869+00
4801	432	utilisateurs	432	LOGIN	null	{"role": "admin", "matricule": "GEST001"}	2026-10-07 15:18:00.461578+00
4802	433	utilisateurs	433	LOGIN	null	{"role": "caissier", "matricule": "CAIS001"}	2026-10-07 18:05:42.501939+00
4803	433	justificatifs	133	DOWNLOAD	null	{"nom_fichier": "WhatsApp Image 2026-10-06 at 11.54.58.jpeg"}	2026-10-07 18:06:56.784914+00
\.


--
-- Data for Name: audit_logs; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.audit_logs (id, user_id, acting_as_user_id, action, entity, entity_id, before, after, reason, device_id, ip, created_at, updated_at) FROM stdin;
3f1e4246-998a-4ed2-a10d-9c7974908759	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-24 11:32:00.318497+00	2026-10-24 11:32:00.318505+00
f7f05de7-ca6f-4155-b3f8-3e39b729239a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	pos-terminal-01	testclient	2026-10-24 12:51:32.743253+00	2026-10-24 12:51:32.743261+00
aaf7fdcb-f3e6-41a0-b717-332031daa94b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-24 23:23:59.05608+00	2026-10-24 23:23:59.056089+00
95a6c230-5361-4ecc-8d3e-b6b709b754a3	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-24 23:24:30.234213+00	2026-10-24 23:24:30.234301+00
7d34a021-9bb6-4e8e-9ffb-0c69e0150b70	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-24 23:26:32.831017+00	2026-10-24 23:26:32.831026+00
5dbf32ac-33d5-4fb1-b3bf-b025ee25f839	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-24 23:27:16.030961+00	2026-10-24 23:27:16.03097+00
af675801-f178-4c45-85bc-459f9e044310	\N	\N	RESET_TRANSACTIONS	SYSTEM	\N	\N	{"deleted_orders": 100, "deleted_order_items": 299, "deleted_payments": 100, "deleted_print_jobs": 0, "deleted_fne": 0, "deleted_sessions": 5, "deleted_cash_movements": 0, "deleted_expenses": 0, "deleted_bank_deposits": 0, "deleted_market_purchases": 1, "deleted_preparations": 25, "deleted_purchase_requests": 0, "deleted_purchase_request_lines": 0, "deleted_outbox_events": 0, "deleted_idempotency_records": 0, "deleted_stock_movements": 0, "reset_stock_articles": 115}	Réinitialisation des transactions via CLI	\N	\N	2026-10-24 23:29:14.464387+00	2026-10-24 23:29:14.464393+00
02aa690c-d79c-4217-99e7-fd7cda283867	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-24 23:42:26.691794+00	2026-10-24 23:42:26.691805+00
fce31ad4-f2b7-43d2-971e-b4f0b7a4768c	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-24 23:53:29.392609+00	2026-10-24 23:53:29.39268+00
b67bee92-b483-4ab5-9523-79a5fb4e1523	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-25 13:53:52.946169+00	2026-10-25 13:53:52.946177+00
c191099e-25da-45ec-9ebe-c9ae8dea07aa	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-25 13:54:01.687998+00	2026-10-25 13:54:01.688007+00
dc3269ab-feef-4f59-9c6f-90683a807831	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-25 13:54:50.034244+00	2026-10-25 13:54:50.034257+00
714fec4a-7219-401a-9ccd-82f0f5b3fb1d	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-25 18:09:37.014767+00	2026-10-25 18:09:37.014775+00
e6f7d2c9-0d20-4781-b36f-839d71c5c2c4	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-25 18:11:09.782735+00	2026-10-25 18:11:09.782743+00
3c923cd7-aec4-4c59-916a-b71ec71e790a	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-25 18:11:20.910548+00	2026-10-25 18:11:20.910557+00
40ddb03c-3e47-40b9-86ff-387bd8d8d398	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-25 18:11:26.845627+00	2026-10-25 18:11:26.845641+00
b118f29c-e93d-4c74-a7ce-6efa02b95dd1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-29 11:10:08.84662+00	2026-10-29 11:10:08.846627+00
05bccb89-9cfa-4709-b957-3fa2260fdf31	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	null	{"opening_float_xof": 100000, "business_date": "2026-10-29"}	\N	caisse-01	\N	2026-10-29 11:10:12.929974+00	2026-10-29 11:10:12.929983+00
f88ecc0a-5296-481e-9790-f82f6b5d5b8e	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-29 11:11:07.241468+00	2026-10-29 11:11:07.241475+00
b7d9635c-b44c-4287-b90b-acc2c585a7cf	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-29 11:11:41.242216+00	2026-10-29 11:11:41.242223+00
d6a8fb35-4ff4-4361-857d-fa585b41e187	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-29 11:11:48.350718+00	2026-10-29 11:11:48.350726+00
e53781bf-c6db-479f-807e-134f7d4dfd21	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 11:11:53.319456+00	2026-10-29 11:11:53.319466+00
9b932ca5-7e5d-4807-9322-cb6b2fcf5349	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-29 11:12:48.648725+00	2026-10-29 11:12:48.648733+00
3715f2f9-c923-411b-ae4e-b7e3b17c7473	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-29 12:14:05.515265+00	2026-10-29 12:14:05.515471+00
fc18652a-16d3-4c55-96d6-f5040104a7f6	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 12:26:22.202299+00	2026-10-29 12:26:22.20231+00
841c7c8b-6639-48e0-9a5f-f6d8d7c60745	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-29 12:31:06.836679+00	2026-10-29 12:31:06.836693+00
2483ba81-6a9d-437a-b22b-1864f0d59473	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-29 12:32:00.123674+00	2026-10-29 12:32:00.123689+00
ed08f3be-eccd-4c95-8df9-1f7e3e03e061	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 12:32:35.175896+00	2026-10-29 12:32:35.175908+00
5a5a139b-edbe-4b8d-b7a2-b8320721ef30	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 12:50:44.191055+00	2026-10-29 12:50:44.191073+00
d68e89d7-db7e-42d6-a1f5-af9c7f6241e3	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 13:57:47.86982+00	2026-10-29 13:57:47.869913+00
aee2d652-8b09-44ec-968c-0bd03c64ee9f	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	pos-terminal-01	127.0.0.1	2026-10-29 14:00:09.205666+00	2026-10-29 14:00:09.205673+00
b87c00fa-d909-4b78-bf5e-dd2d82dc1b44	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 14:31:42.859109+00	2026-10-29 14:31:42.859125+00
dfd51d4d-7703-47c1-a075-9c862cbdb55b	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 14:51:35.159221+00	2026-10-29 14:51:35.159234+00
37fb43df-2ede-42fd-a472-64a1f26daac6	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:10:36.013572+00	2026-10-29 15:10:36.013581+00
1fc80478-dbb4-4e66-9e6c-ca27d4f9fa3f	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:11:08.334645+00	2026-10-29 15:11:08.334653+00
afbd7dea-2492-45b5-b621-63e240a6936f	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:20:39.382988+00	2026-10-29 15:20:39.382995+00
0afb906f-e2c1-4570-95eb-739ffc3f4672	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:21:45.437459+00	2026-10-29 15:21:45.437467+00
0abc294b-e3ef-41b7-b3a2-8e0002449d27	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:34:37.715406+00	2026-10-29 15:34:37.715418+00
6105f4fa-5df6-407e-80ae-f4fefb5da00d	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:46:20.606023+00	2026-10-29 15:46:20.606031+00
e5f24772-66e6-4abb-a9c2-830451e91c91	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:47:04.794273+00	2026-10-29 15:47:04.794281+00
2e0be327-0e54-4a0b-bd95-ec29efaee38a	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:49:14.598674+00	2026-10-29 15:49:14.598683+00
30bb6d2f-00b3-417c-8d1d-8e701b9c3899	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-29 15:49:47.867832+00	2026-10-29 15:49:47.867839+00
ea039483-f673-4242-b700-76f7395f2b6d	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-29 15:49:52.885737+00	2026-10-29 15:49:52.885745+00
5e0cd1c0-d060-4831-afb9-df31fbdc218c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:49:56.086749+00	2026-10-29 15:49:56.086756+00
4bd7104d-9541-43d0-b273-8ba5a03b556f	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:50:26.089914+00	2026-10-29 15:50:26.089924+00
5992e034-2c8a-4550-93fe-9c419d6b6d34	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:51:13.233618+00	2026-10-29 15:51:13.233626+00
f3262851-5ad8-42e5-aeeb-867cfaa288c1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	03f1433e-f79b-47f1-923c-55a1b3061ef8	null	{"order_number": "2026-10-29-0001", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-29 15:51:28.660304+00	2026-10-29 15:51:28.660317+00
614ae1f6-365d-4236-a40a-615003d1e760	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	886a1abb-1324-4132-ab3d-d85de26466f7	null	{"name": "Kabato Dah + Poulet", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:51:28.842577+00	2026-10-29 15:51:28.842585+00
6c792193-bf46-4cfc-b788-4f15a9a055d0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	fe43491c-8379-4c80-9019-4980d9ea4046	null	{"name": "Kabato Dah + Poisson", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-29 15:51:28.960932+00	2026-10-29 15:51:28.960944+00
402bfea6-1044-4896-8e20-b19412af65aa	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec	null	{"name": "Kabato Kope + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:51:29.073206+00	2026-10-29 15:51:29.073214+00
bde6c2ad-f7b0-4832-8b7c-078e35bd3320	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	f6516bfe-a30a-4469-a223-235df3a1cf4f	null	{"name": "Kabato Dah + B\\u0153uf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:51:29.192393+00	2026-10-29 15:51:29.192404+00
d914b7a8-9868-42d2-8d9b-629a05e8d504	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	651ad9da-668d-41ca-98bd-fd5c693b36af	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:51:29.293427+00	2026-10-29 15:51:29.293435+00
e3c5507a-d403-4da1-978f-8353f7aff43b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c33981ba-c745-446d-99bd-efccdca207da	null	{"name": "Atti\\u00e9k\\u00e9 + Poulet", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:51:29.396817+00	2026-10-29 15:51:29.396826+00
77a7fb2c-73e1-4de6-a383-9e6f9cc0dd2e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4d790f5e-2f4b-4210-b0a6-eefb52b3e773	null	{"name": "Alloco + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-29 15:51:29.500378+00	2026-10-29 15:51:29.500387+00
4b8e0b0b-2897-4e20-ae14-4a661d02b520	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	2529e749-aa73-40b1-9478-8e0738879f53	null	{"name": "Petit pois + B\\u0153uf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:51:29.605265+00	2026-10-29 15:51:29.605274+00
ce2a7316-0f55-4310-b5fc-9df9d0145c64	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b5f69c09-9d24-4966-82fc-2f95a163bfb1	null	{"name": "Petit pois + Sosso 3500", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-29 15:51:29.723368+00	2026-10-29 15:51:29.723375+00
98d3e893-39b0-4756-adc1-257ec2f202de	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	4df61102-c27c-4879-8ed2-15b88304cd09	null	{"order_number": "2026-10-29-0002", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 1}	\N	caisse-01	\N	2026-10-29 15:51:48.424518+00	2026-10-29 15:51:48.424526+00
1e2d344f-2d70-4bc9-b9a2-e3d5a828a6c9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c03f81d8-1777-4c8b-9c91-8c0690d4555a	null	{"name": "Kabato Kope + Poulet", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:52:04.200523+00	2026-10-29 15:52:04.200532+00
276b5f5f-60f3-4e79-ad8e-f70df8ceb747	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b033f55d-efa9-4237-bbcc-a0a118c42d13	null	{"name": "Kabato Dah + Poisson", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-29 15:52:04.29936+00	2026-10-29 15:52:04.299367+00
e3dfa3a4-9067-44fd-8450-d8396863ca15	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	32cf20d8-7aad-47df-a0bd-9577a68f574c	null	{"name": "Kabato Kope + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:52:04.406939+00	2026-10-29 15:52:04.406947+00
6905568e-e03e-4a0a-959d-64fde4e4640c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b0d9289b-e7f3-44f7-9bc4-2caad7472828	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:52:04.496737+00	2026-10-29 15:52:04.496745+00
6f71f3df-14c8-4db4-92e2-e18d1c6db13b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	bb293b3e-c92f-49b7-9263-6bab906285f9	null	{"name": "Igname frite + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-29 15:52:04.581972+00	2026-10-29 15:52:04.581978+00
75c50283-8acc-4449-aff5-507209b4c441	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	023cf862-5641-4a2e-b690-00429131a979	null	{"name": "Atti\\u00e9k\\u00e9 + Boeuf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:52:04.669587+00	2026-10-29 15:52:04.669595+00
d8c4bb14-2f24-4778-b734-828e7c156e22	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b3526943-6b8d-4a08-9516-18f61ad84c12	null	{"name": "Alloco + Poulet", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:52:04.758426+00	2026-10-29 15:52:04.758433+00
a74c4e54-95ef-430d-baae-d430f0c73a2e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	88811e0e-bea9-4939-a16d-7456e20b1d2e	null	{"name": "Petit pois + B\\u0153uf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 15:52:04.842782+00	2026-10-29 15:52:04.842791+00
ff14ce5a-faca-4dd5-a43f-f561ed568ec1	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 16:36:54.036019+00	2026-10-29 16:36:54.036031+00
9ce13d84-adb2-4322-8d17-49aaefc8d876	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	36ef37f6-2243-41bf-b2bf-e6a4f04c251b	null	{"order_id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "amount_xof": 30000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-29 15:52:41.716084+00	2026-10-29 15:52:41.716091+00
81b2dbe1-ddf4-479c-88f6-a47452883aae	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	af169dc1-29a2-4501-8f71-1bbe83177f2e	null	{"order_id": "4df61102-c27c-4879-8ed2-15b88304cd09", "amount_xof": 25000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-29 15:53:45.927974+00	2026-10-29 15:53:45.927981+00
03aa58f8-2c96-438a-8c7e-52c7b43d8437	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 15:54:14.365926+00	2026-10-29 15:54:14.365933+00
567d322b-2657-4e88-8891-06114a7d98ff	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 16:30:49.783359+00	2026-10-29 16:30:49.783368+00
e92cb273-1368-4c4d-8cbd-406f2d3db777	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-29 16:32:50.537763+00	2026-10-29 16:32:50.537775+00
3dba971a-d770-4b8d-83d3-64de398dee82	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-29 16:32:53.687016+00	2026-10-29 16:32:53.687024+00
07d21d7c-8130-4bde-aa9e-dfda003ae1e7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	null	{"order_number": "2026-10-29-0003", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "guests_count": 4}	\N	caisse-01	\N	2026-10-29 16:33:12.857985+00	2026-10-29 16:33:12.857998+00
0e196aba-8406-40c3-8cca-06db402ec202	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	52cacaa5-7d53-41fe-8e84-616f049e5043	null	{"name": "Igname bouillie + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-29 16:33:13.012476+00	2026-10-29 16:33:13.012485+00
004ba670-6409-47a8-a1d0-59c215c6b318	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	5884e7fb-f015-4316-8833-f3da0c3ddeed	null	{"name": "Atti\\u00e9k\\u00e9 + Boeuf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 16:33:13.131846+00	2026-10-29 16:33:13.131855+00
b4a70455-0a63-491c-bda5-0de59d176a5f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	53813ee6-0602-4f66-88d0-bb3079b78275	null	{"name": "Alloco + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-29 16:33:13.251287+00	2026-10-29 16:33:13.251299+00
ea7b2370-2a84-429d-932c-a41155914109	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	10da25f8-2495-4165-b908-37c7fd9f821b	null	{"name": "Salade Panach\\u00e9e + Poulet", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 16:33:13.403407+00	2026-10-29 16:33:13.403417+00
4fe2068a-33df-4593-a180-931470bba697	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6b6248ae-cd37-4b18-a89b-f73c403b9622	null	{"name": "Salade Fra\\u00eeche + Poulet", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 16:33:13.511266+00	2026-10-29 16:33:13.511276+00
5a1a0c69-0842-487d-accc-c821799c8c75	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a36043cf-1af4-4f12-a5d3-28386af12cdc	null	{"name": "Salade Fra\\u00eeche + Sosso 4000", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-29 16:33:13.626146+00	2026-10-29 16:33:13.62616+00
6fe9c54b-4b7e-42d3-a9bf-6b087c7735b1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	44233049-ad0f-420f-9fc7-c94a58dba425	null	{"name": "Salade Panach\\u00e9e + Sosso 5000", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-29 16:33:13.73671+00	2026-10-29 16:33:13.736723+00
9d74de81-0e29-4120-96d5-aeff630df771	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	dcedcffe-336a-4484-988f-b28e1a2e7ba0	null	{"order_number": "2026-10-29-0004", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "guests_count": 4}	\N	caisse-01	\N	2026-10-29 16:33:44.624542+00	2026-10-29 16:33:44.624552+00
f2695e8c-afcf-4efc-89d7-cc188214a446	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1b705b20-098e-4504-8b97-1b53a198a141	null	{"name": "Sosso 3500", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-29 16:33:44.749262+00	2026-10-29 16:33:44.749272+00
6c3fa2aa-2d96-48e5-996f-4b93e63ac68f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1b32cc23-9ad8-4a45-97c9-fb91c0d24abb	null	{"name": "Sosso 7000", "quantity": 1, "line_total_xof": 7000}	\N	caisse-01	\N	2026-10-29 16:33:44.896671+00	2026-10-29 16:33:44.896681+00
6bb84ac5-1909-428c-97b8-d41c30266500	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ddc6864b-3904-41f3-9f3a-b791af71aedc	null	{"name": "Kabato Kope + Poulet", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 16:33:45.06657+00	2026-10-29 16:33:45.066579+00
ad30dda1-c377-44f8-baa6-2ab9401396a2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	34a0bc05-7144-4cf4-b542-2edb6a271273	null	{"name": "Kabato Lafri + Boeuf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 16:33:45.199243+00	2026-10-29 16:33:45.199254+00
9c138af7-bf7d-4550-8c70-7ef830cf2059	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	cf4f9468-9d80-4cd0-a28f-f3ea46ac8ff2	null	{"name": "Kabato Dah + Boeuf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 16:33:45.328082+00	2026-10-29 16:33:45.328093+00
77574085-903a-457e-a861-92b998c6358e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	db889a3d-91e0-478f-ba4e-e266bcdccd46	null	{"name": "Kabato Lafri + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-29 16:33:45.430993+00	2026-10-29 16:33:45.431006+00
887f3c6a-70a1-490c-90d6-bdca967eefaa	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	8e61150a-5664-470a-8ae3-ee2f8a2bdb4d	null	{"name": "Couscous + Poulet", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-29 16:33:45.547739+00	2026-10-29 16:33:45.547749+00
bc0703a0-f80a-41b1-b881-85df6f668273	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3ff47e3f-82e6-45f4-8ae4-a4e854c07bcc	null	{"name": "Couscous + Poisson", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-29 16:33:45.641472+00	2026-10-29 16:33:45.641482+00
f8f827e6-cacb-479b-8216-bbbea5ea7aa1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	96301ae0-6da5-4801-81e0-e95b2025e5c6	null	{"name": "Couscous + Mouton", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-29 16:33:45.742204+00	2026-10-29 16:33:45.742216+00
5b8c16aa-a0d5-4829-a7b0-9be2aa939324	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	8716e1cf-8b3e-4a32-aeb2-19664ccb9ae7	null	{"order_id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "amount_xof": 33500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-29 16:33:55.838884+00	2026-10-29 16:33:55.838892+00
efc127a6-da10-4be0-896b-0a7ae4fec350	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	7aeb51d0-f90a-45b0-9577-87bb37396bb8	null	{"order_id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "amount_xof": 26000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-29 16:34:14.358919+00	2026-10-29 16:34:14.358929+00
71cd5490-52f5-4ca9-bb5d-05c43fa01387	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 16:34:29.723262+00	2026-10-29 16:34:29.723273+00
429273bb-4b16-4eb7-ba4c-ab67212ae228	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-29 16:35:47.368578+00	2026-10-29 16:35:47.368588+00
24738591-5eda-4050-885b-656da958a093	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	null	{"z_number": 1, "counted_cash_xof": 214500, "expected_cash_xof": 214500, "variance_xof": 0}	\N	caisse-01	\N	2026-10-29 16:36:46.077802+00	2026-10-29 16:36:46.077813+00
c4f04f90-9a39-4c83-85b5-b9987a333861	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 16:52:02.275127+00	2026-10-29 16:52:02.275135+00
961ad0ad-805c-4044-af95-001aaa1a789b	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 17:09:45.193123+00	2026-10-29 17:09:45.193134+00
4f892f10-cf0f-42f3-9b63-692a01f23e7e	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 17:25:04.22377+00	2026-10-29 17:25:04.22378+00
b2b45876-416e-444f-a354-ce05befdc296	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 18:10:52.086702+00	2026-10-29 18:10:52.086709+00
a95dbb0e-fc43-42a9-a3d0-1f7cdc20ccda	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-29 18:33:55.038972+00	2026-10-29 18:33:55.039049+00
a8708b70-23ac-41f6-80be-e42d94d9614d	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 09:32:19.239257+00	2026-10-30 09:32:19.239267+00
12bab14e-9b36-45b0-9378-53028a8eb062	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-30 09:37:10.801217+00	2026-10-30 09:37:10.801336+00
791425e0-9404-4a8f-bb83-42f794a9b813	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-30 09:37:13.985183+00	2026-10-30 09:37:13.98519+00
a07dc6bb-a6f3-434a-b637-290ef5e291bf	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 09:41:50.514359+00	2026-10-30 09:41:50.514373+00
0a045d28-0df2-4777-baf9-64a1f7e3b5f6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-30 10:18:48.776152+00	2026-10-30 10:18:48.776262+00
7479ee9f-39b4-4d27-acc2-0b33807c51e9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	null	{"opening_float_xof": 100000, "business_date": "2026-10-30"}	\N	caisse-01	\N	2026-10-30 10:18:52.340019+00	2026-10-30 10:18:52.340026+00
9687fdc4-ec84-46e0-93ff-5b3a46503ed8	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 10:22:03.358756+00	2026-10-30 10:22:03.358763+00
d3ee6ad7-67e2-4a6f-a467-d53b8a38d61c	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 10:38:24.006987+00	2026-10-30 10:38:24.006996+00
8dc07dd7-1df6-4193-b262-f0bc21a01fb5	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 10:55:16.220993+00	2026-10-30 10:55:16.221088+00
b940eee8-a938-450b-8359-6d25c8325966	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-30 11:03:11.187062+00	2026-10-30 11:03:11.187073+00
acb49c9c-f2c6-462b-9ae9-6c846d51e809	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-30 11:03:13.965419+00	2026-10-30 11:03:13.96543+00
7beaebe4-31db-4f90-b9b8-1a8284b865e5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	05ad026a-7ca3-47fe-a3c6-93ca6b508870	null	{"order_number": "2026-10-30-0001", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 1}	\N	caisse-01	\N	2026-10-30 11:03:22.784714+00	2026-10-30 11:03:22.784721+00
0d32e3da-e476-44d7-8ccc-846f3ff602d0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ea48c73b-7797-4838-9f2f-ecc20058df81	null	{"name": "Kabato Kope + Boeuf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-30 11:03:47.873181+00	2026-10-30 11:03:47.873189+00
70968af9-e3bd-48f6-9353-422c9424926e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	ece75c3c-3e70-41d0-bb85-cdf0d7ca0cbf	null	{"order_id": "05ad026a-7ca3-47fe-a3c6-93ca6b508870", "amount_xof": 3000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-30 11:05:12.097044+00	2026-10-30 11:05:12.097058+00
b614e347-ae40-486f-8758-0715cebd1c52	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-30 11:08:18.368828+00	2026-10-30 11:08:18.368838+00
a5149a71-d9db-45af-a785-3e92f1a1e193	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-30 11:08:24.24889+00	2026-10-30 11:08:24.248899+00
0e8a9e05-8283-4767-861e-04df7c8fc7b2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	1b4709eb-7431-4782-8ff3-bd821ed4b2ec	null	{"order_number": "2026-10-30-0002", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "guests_count": 4}	\N	caisse-01	\N	2026-10-30 11:10:11.862948+00	2026-10-30 11:10:11.862958+00
a8371090-f94f-416c-b15b-506dec673923	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	079270e7-fdd9-47c8-ae6e-580f83a4d0ed	null	{"name": "Kabato Kope + Boeuf", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-30 11:10:11.955389+00	2026-10-30 11:10:11.9554+00
b19f7659-3a98-4434-9045-7e7189780a7c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	a00ab204-76cc-41e3-a653-4bca4eb1fa69	null	{"order_id": "1b4709eb-7431-4782-8ff3-bd821ed4b2ec", "amount_xof": 3000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-30 11:10:16.666535+00	2026-10-30 11:10:16.666546+00
44f3062d-039d-4d02-96de-0e1abe506f21	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 11:10:41.787395+00	2026-10-30 11:10:41.787406+00
07adf8af-46f7-418a-bfd7-f3b6fc41b60a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-30 11:11:23.086936+00	2026-10-30 11:11:23.086947+00
f1511209-42d2-44fb-ab6a-10a00f985155	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	c9bc61b4-ad71-4a9f-93c6-918d772fb438	null	{"order_number": "2026-10-30-0003", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "guests_count": 4}	\N	caisse-01	\N	2026-10-30 11:12:00.873894+00	2026-10-30 11:12:00.873903+00
c6842f94-4423-4496-843a-4b081f942d35	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ae8c1b03-97ca-4fca-b599-b62195f3cd51	null	{"name": "Foutou + Pistache poisson", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:12:00.96946+00	2026-10-30 11:12:00.969469+00
7a1bd8dc-9b2d-4e98-8cf0-dbf1f9c02ca9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	70224647-ff1a-405c-844c-62c1b1d3130b	null	{"name": "Foutou gouagouassou + Mouton", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-30 11:12:01.069021+00	2026-10-30 11:12:01.069032+00
9235714e-156c-4f2d-a0c2-5ada53851159	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a585b556-87e4-4302-8160-a2a342eb99d4	null	{"name": "Foutou gouagouassou + Poisson", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:12:01.176399+00	2026-10-30 11:12:01.176407+00
7baa8f30-99c1-4143-9fd5-c23bff48b14d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6099bd33-f0d3-42ed-ad6b-c13d3f74e1fe	null	{"name": "Foutou gouagouassou + Poulet", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:12:01.27314+00	2026-10-30 11:12:01.273148+00
c3ac537a-63b1-4e24-8be3-5e5effa6bf59	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	de335dd4-55c1-44a5-9a9e-569dcec3f62f	null	{"name": "Foutou graine + B\\u0153uf", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:12:01.355313+00	2026-10-30 11:12:01.355322+00
d074221e-3d47-45ea-8017-4aa90c205d00	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d62d4f89-0e16-482e-ae46-95334f9006c5	null	{"name": "Foutou graine + Mouton", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-30 11:12:01.432527+00	2026-10-30 11:12:01.432537+00
3b99ebe1-6ef0-4a05-98e0-34a6ab8a5d20	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	30da91b1-bd3a-4ffe-9a86-f0ffb4e157b8	null	{"name": "Foutou graine + Poulet", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:12:01.512637+00	2026-10-30 11:12:01.512645+00
32fe837d-7491-4e08-9c53-3d24ee18b83f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	b435a1c1-0b7b-44df-8887-03062f0e071c	null	{"order_id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "amount_xof": 25500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-30 11:12:16.173884+00	2026-10-30 11:12:16.173897+00
8c4ffb04-9192-4b48-95ab-84d3ebf9777b	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 11:12:28.921922+00	2026-10-30 11:12:28.921953+00
2f153457-9fd8-4d2f-8212-62a63660d695	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 11:31:43.430367+00	2026-10-30 11:31:43.430375+00
411bc3da-4c91-4623-ae78-5a0b2ce760be	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-30 11:32:15.440401+00	2026-10-30 11:32:15.44041+00
528e206e-ba3b-42b5-8282-661d8e26e800	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	ff8f5b34-95af-4d39-90dd-2308a7d41876	null	{"order_number": "2026-10-30-0004", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "guests_count": 4}	\N	caisse-01	\N	2026-10-30 11:32:36.854978+00	2026-10-30 11:32:36.854988+00
80ce95ae-a587-4aa5-9f5e-2bf897de28da	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	8cc4a9e5-1b4f-4342-a8a2-1d1bb8419de8	null	{"name": "Foufou/foutou b\\u0153uf", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:32:36.955065+00	2026-10-30 11:32:36.955076+00
2a6b7e10-9429-4355-9a6a-8f45565cd6d6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0289f245-63b2-4ce2-8774-924e3a3d5727	null	{"name": "Foufou/foutou poulet", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:32:37.056728+00	2026-10-30 11:32:37.056738+00
e756e56b-e4a6-4505-b345-f1ee0f2d3d88	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	81f15313-d890-43b7-8a5f-2d6abacf0299	null	{"name": "Foufou sauce claire + B\\u0153uf", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:32:37.178563+00	2026-10-30 11:32:37.178571+00
7111538f-1479-44f4-a8cc-708d77da52f3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	080cefe1-d22d-4e91-984b-b20f3dcc7992	null	{"name": "Foufou sauce claire + Poulet", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-30 11:32:37.260962+00	2026-10-30 11:32:37.260971+00
d2773f0e-bf49-4d3d-b208-0e84b49bb8b0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	684a5a0a-b655-4e10-89ae-6c1654c74a77	null	{"order_id": "ff8f5b34-95af-4d39-90dd-2308a7d41876", "amount_xof": 14000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-30 11:32:46.365492+00	2026-10-30 11:32:46.365501+00
ff9fdedd-20c2-4100-abea-497f6e24741b	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-30 11:33:00.134521+00	2026-10-30 11:33:00.134531+00
\.


--
-- Data for Name: autorisations_depense; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.autorisations_depense (id, caisse_journee_id, demandeur, date_demande, dossier, objet, montant, statut, approuve_par, approuve_le, created_at) FROM stdin;
69	451	SOLIBRA	2026-09-05	\N	Eau Awa	135000.00	approuvee	432	2026-09-05 18:31:05.864933+00	2026-09-05 18:01:44.762467+00
247	1080	Fournisseur EUROLAIT	2026-09-07	\N	Achat de produit laitier	256000.00	approuvee	432	2026-09-07 11:22:58.137705+00	2026-09-07 11:21:33.529664+00
248	1080	SYLLA FRERE	2026-09-07	234040	ACHAT DE RIZ	480000.00	approuvee	432	2026-09-07 11:49:12.682929+00	2026-09-07 11:47:07.601286+00
467	1752	SYLLA FRERE	2026-09-28	\N	ACHAT DE RIZ	450000.00	approuvee	2419	2026-09-28 11:40:27.750712+00	2026-09-28 11:35:38.724986+00
513	1949	SYLLA FRERE	2026-10-07	\N	ACHAT DE RIZ	435000.00	approuvee	432	2026-10-07 10:56:53.665462+00	2026-10-07 10:38:57.643201+00
62	370	SOLIBRA	2026-09-04	\N	ACHAT EAU AWA	153200.00	approuvee	432	2026-09-04 15:24:17.560509+00	2026-09-04 15:23:12.877876+00
264	1136	REGLEMENT PARTIEL DU PERSONNEL	2026-09-08	\N	REGLEMENT PARTIEL DU SALAIRE DU PERSONNEL	220000.00	approuvee	432	2026-09-08 14:18:41.966291+00	2026-09-08 14:17:32.131632+00
\.


--
-- Data for Name: bank_deposits; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.bank_deposits (id, business_date, user_id, amount_xof, bank_name, slip_number, deposited_by, notes, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: billetage_comptage; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.billetage_comptage (id, caisse_journee_id, denomination_id, nombre) FROM stdin;
473	1080	1	40
474	1080	2	10
475	1080	3	20
476	1080	4	1
477	1080	5	0
478	1080	6	0
479	1080	7	0
480	1080	8	0
481	1080	9	1
482	1080	10	0
483	1080	11	0
484	1080	12	0
151	271	1	10
152	271	2	20
153	271	3	20
154	271	4	30
155	271	5	31
156	271	6	21
157	271	7	20
158	271	8	20
159	271	9	0
160	271	10	0
161	271	11	0
162	271	12	0
103	270	1	30
104	270	2	4
105	270	3	1
106	270	4	1
107	270	5	0
108	270	6	0
109	270	7	0
110	270	8	0
111	270	9	0
112	270	10	0
113	270	11	0
114	270	12	0
584	1261	1	50
585	1261	2	11
586	1261	3	10
587	1261	4	20
238	370	1	30
239	370	2	20
240	370	3	50
241	370	4	0
242	370	5	0
243	370	6	0
244	370	7	0
245	370	8	0
246	370	9	0
247	370	10	0
248	370	11	0
249	370	12	0
262	451	1	75
263	451	2	5
264	451	3	5
265	451	4	0
266	451	5	0
267	451	6	0
268	451	7	0
269	451	8	0
270	451	9	0
271	451	10	0
272	451	11	0
273	451	12	0
588	1261	5	0
589	1261	6	0
590	1261	7	1
591	1261	8	0
592	1261	9	1
593	1261	10	0
594	1261	11	0
595	1261	12	0
505	1136	1	73
506	1136	2	5
507	1136	3	5
508	1136	4	5
509	1136	5	7
510	1136	6	0
511	1136	7	1
512	1136	8	10
513	1136	9	1
514	1136	10	0
515	1136	11	0
516	1136	12	0
771	1752	1	80
772	1752	2	10
773	1752	3	10
774	1752	4	0
775	1752	5	0
776	1752	6	0
777	1752	7	1
778	1752	8	0
779	1752	9	1
780	1752	10	0
781	1752	11	0
782	1752	12	0
824	1949	1	40
825	1949	2	0
826	1949	3	0
827	1949	4	0
828	1949	5	0
829	1949	6	0
830	1949	7	0
831	1949	8	0
832	1949	9	0
833	1949	10	0
834	1949	11	0
835	1949	12	0
\.


--
-- Data for Name: cahier_tresorerie; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.cahier_tresorerie (id, superette_id, caisse_journee_id, date_mouvement, type_mouvement, libelle, montant, solde_avant, solde_apres, saisi_par, created_at) FROM stdin;
345	377	1080	2026-09-07	diminution	Flux net caisse du 2026-09-07 (- Dépenses nettes)	293950.00	785000.00	491050.00	432	2026-09-07 13:53:27.228035+00
61	377	270	2026-09-02	augmentation	Report solde caisse du 2026-09-02	323000.00	0.00	323000.00	432	2026-09-02 15:59:34.821226+00
122	377	370	2026-09-04	augmentation	Flux net caisse du 2026-09-04 (+ Recettes nettes)	203250.00	296750.00	500000.00	432	2026-09-04 16:12:13.067269+00
123	377	451	2026-09-05	augmentation	Flux net caisse du 2026-09-05 (+ Recettes nettes)	285000.00	500000.00	785000.00	432	2026-09-05 18:44:40.369494+00
355	377	1136	2026-09-08	augmentation	Flux net caisse du 2026-09-08 (+ Recettes nettes)	283700.00	491050.00	774750.00	432	2026-09-08 15:38:00.67424+00
421	377	1261	2026-09-10	diminution	Flux net caisse du 2026-09-10 (- Dépenses nettes)	179500.00	774750.00	595250.00	432	2026-09-10 14:56:50.244935+00
77	377	271	2026-09-03	diminution	Flux net caisse du 2026-09-03 (- Dépenses nettes)	26250.00	323000.00	296750.00	432	2026-09-03 15:35:36.214778+00
674	377	1752	2026-09-28	augmentation	Flux net caisse du 2026-09-28 (+ Recettes nettes)	275000.00	595250.00	870250.00	2419	2026-09-28 12:15:06.763595+00
702	377	1949	2026-10-07	diminution	Flux net caisse du 2026-10-07 (- Dépenses nettes)	465000.00	870250.00	405250.00	2419	2026-10-07 15:17:46.890909+00
\.


--
-- Data for Name: caisse_journees; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.caisse_journees (id, superette_id, date_operation, solde_veille, total_encaissements, total_decaissements, total_billetage, commentaire_ecart, statut, ouverte_par, cloturee_par, cloturee_le, validee_par, validee_le, commentaire_validation, created_at, billetage_effectue) FROM stdin;
271	377	2026-09-03	323000.00	123250.00	149500.00	296750.00	\N	validee	433	433	2026-09-03 15:34:12.621965+00	432	2026-09-03 15:35:36.249354+00	\N	2026-09-03 07:43:47.746896+00	t
270	377	2026-09-02	0.00	323000.00	0.00	323000.00	\N	validee	433	433	2026-09-02 15:58:16.096207+00	432	2026-09-02 15:59:34.852903+00	\N	2026-09-02 11:15:59.975372+00	t
370	377	2026-09-04	296750.00	520000.00	316750.00	500000.00	\N	validee	433	433	2026-09-04 16:10:56.793798+00	432	2026-09-04 16:12:13.082005+00	\N	2026-09-04 09:20:39.737004+00	t
1080	377	2026-09-07	785000.00	555000.00	848950.00	491050.00	\N	validee	433	433	2026-09-07 13:52:08.053235+00	432	2026-09-07 13:53:27.257284+00	\N	2026-09-07 10:44:33.238916+00	t
451	377	2026-09-05	500000.00	350000.00	65000.00	785000.00	\N	validee	433	433	2026-09-05 18:43:28.261499+00	432	2026-09-05 18:44:40.38024+00	\N	2026-09-05 17:54:22.068301+00	t
1261	377	2026-09-10	774750.00	0.00	179500.00	595250.00	\N	validee	433	433	2026-09-10 14:55:37.032812+00	432	2026-09-10 14:56:50.283075+00	\N	2026-09-10 13:55:51.424755+00	t
1752	377	2026-09-28	595250.00	725000.00	450000.00	870250.00	\N	validee	433	433	2026-09-28 12:13:57.148259+00	2419	2026-09-28 12:15:06.783704+00	\N	2026-09-28 11:26:27.826953+00	t
1136	377	2026-09-08	491050.00	905000.00	621300.00	774750.00	\N	validee	433	433	2026-09-08 15:19:19.394461+00	432	2026-09-08 15:38:00.71028+00	\N	2026-09-08 10:30:01.287806+00	t
1949	377	2026-10-07	870250.00	15000.00	480000.00	400000.00	Erreur de rendu monnaie en caisse	validee	433	433	2026-10-07 15:16:41.408916+00	2419	2026-10-07 15:17:46.907918+00	\N	2026-10-07 10:23:55.241388+00	t
\.


--
-- Data for Name: cash_expenses; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.cash_expenses (id, business_date, cash_session_id, user_id, category, amount_xof, recipient, reason, receipt_reference, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: cash_movements; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.cash_movements (id, cash_session_id, user_id, type, amount_xof, reason, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: cash_registers; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.cash_registers (id, name, printer_config, is_active, created_at, updated_at) FROM stdin;
0192384a-3000-7000-8000-000000000001	Caisse Principale	\N	t	2026-10-03 16:12:32.729226+00	2026-10-03 16:12:32.729234+00
caisse-01	Caisse 01 (Bar / Principal)	\N	t	2026-10-03 16:54:16.623973+00	2026-10-03 16:54:16.623973+00
caisse-02	Caisse 02 (Terrasse / Mobile)	\N	f	2026-10-03 16:54:16.623973+00	2026-10-29 17:21:10.737142+00
\.


--
-- Data for Name: cash_sessions; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.cash_sessions (id, cash_register_id, opened_by_user_id, closed_by_user_id, business_date, status, opening_float_xof, opened_at, closed_at, z_number, expected_cash_xof, counted_cash_xof, variance_xof, closing_breakdown, totals_snapshot, notes, created_at, updated_at) FROM stdin;
43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29	CLOSED	100000	2026-10-29 11:10:12.922192+00	2026-10-29 16:36:46.050337+00	1	214500	214500	0	{"2000": 2, "10000": 21, "coin_500": 1}	{"z_number": 1, "opening_float_xof": 100000, "total_sales_ttc_xof": 114500, "total_sales_ht_xof": 114500, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 114500}, "sales_by_category": {"Poissons": 10500, "Sp\\u00e9cial Kabato": 34500, "Sp\\u00e9cial Oriental": 10500, "Sp\\u00e9cial Ivoirienne": 44000, "Sp\\u00e9cial Salade": 15000}, "sales_by_item": [{"product_name": "Sosso 7000", "category": "Poissons", "quantity": 1, "unit_price_xof": 7000, "total_ttc_xof": 7000}, {"product_name": "Kabato Dah + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3500, "total_ttc_xof": 7000}, {"product_name": "Kabato Kope + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Atti\\u00e9k\\u00e9 + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Kabato Kope + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Frites + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Petit pois + B\\u0153uf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Salade Panach\\u00e9e + Sosso 5000", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Alloco + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Couscous + Mouton", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Igname bouillie + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Alloco + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Salade Fra\\u00eeche + Sosso 4000", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Sosso 3500", "category": "Poissons", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Kabato Lafri + Mouton", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Couscous + Poisson", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Petit pois + Sosso 3500", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Igname frite + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Kabato Lafri + Boeuf", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Kabato Dah + Boeuf", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Couscous + Poulet", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Salade Panach\\u00e9e + Poulet", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Salade Fra\\u00eeche + Poulet", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Kabato Dah + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Kabato Dah + B\\u0153uf", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Atti\\u00e9k\\u00e9 + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Alloco + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 214500, "counted_cash_xof": 214500, "variance_xof": 0, "closing_breakdown": {"2000": 2, "10000": 21, "coin_500": 1}, "orders_count": 4, "cancelled_orders_count": 0}	\N	2026-10-29 11:10:12.924894+00	2026-10-29 16:36:46.081881+00
e392e6cf-0283-47b9-b17f-c0400f0f0a6f	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	2026-10-30	OPEN	100000	2026-10-30 10:18:52.303493+00	\N	\N	\N	\N	\N	\N	\N	\N	2026-10-30 10:18:52.332735+00	2026-10-30 10:18:52.332742+00
\.


--
-- Data for Name: categories; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.categories (id, name, kind, sort_order, color, fiscal_group, is_active, created_at, updated_at) FROM stdin;
c10d7361-d445-4d51-a087-7e05d6aae6cd	Spécial Kabato	FOOD	1	ambre	FOOD	t	2026-10-06 10:44:50.63677+00	2026-10-06 10:44:50.636786+00
b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Spécial Sauce	FOOD	2	vert	FOOD	t	2026-10-06 10:44:50.706297+00	2026-10-06 10:44:50.706305+00
b8baea0e-44c7-46eb-807f-a553310c5f7c	Spécial Oriental	FOOD	3	orange	FOOD	t	2026-10-06 10:44:50.752672+00	2026-10-06 10:44:50.75268+00
06c1be01-2539-411a-9a12-89674460c795	Spécial Salade	FOOD	4	cyan	FOOD	t	2026-10-06 10:44:50.769801+00	2026-10-06 10:44:50.769809+00
844d467e-f25a-4721-b050-f0aa823fe817	Spécial Sénégal	FOOD	5	rouge	FOOD	t	2026-10-06 10:44:50.790663+00	2026-10-06 10:44:50.79067+00
8f3be9d2-6b4b-4c36-8970-b87c90101139	Spécial Ivoirienne	FOOD	6	brun	FOOD	t	2026-10-06 10:44:50.826139+00	2026-10-06 10:44:50.826148+00
39443ae1-ee99-4f2e-a739-5f60cafbc6fe	Spécial Desserts	FOOD	7	rose	FOOD	t	2026-10-06 10:44:50.939507+00	2026-10-06 10:44:50.939515+00
74b13cc9-1d3b-41d7-80c4-88573b1e7812	Spécial Jus	DRINK	8	bleu	DRINK	t	2026-10-06 10:44:50.951979+00	2026-10-06 10:44:50.951987+00
49ce3191-0c59-453e-ba4f-921458c9629c	Viandes	FOOD	0	\N	VIANDES	t	2026-10-20 15:03:07.728338+00	2026-10-20 15:03:07.728345+00
37f33917-e947-438e-a046-1530d7dced56	Poissons	FOOD	0	\N	POISSONS	t	2026-10-20 15:03:07.7517+00	2026-10-20 15:03:07.751708+00
8c3313e1-5e72-4262-9eed-79fb512a9661	Foufou / foutou	FOOD	0	\N	PLATS	t	2026-10-20 15:03:07.806573+00	2026-10-20 15:03:07.806581+00
14f64e21-345b-4e83-8013-84b96f36d717	Jus	FOOD	0	\N	JUS	t	2026-10-20 15:03:07.851161+00	2026-10-20 15:03:07.851169+00
b37e8530-2a55-4840-8d02-44dac8c38f9b	Sucreries	FOOD	0	\N	JUS	t	2026-10-20 15:03:07.872229+00	2026-10-20 15:03:07.872237+00
7bd0dcc5-e575-459d-a8be-5e5aab739953	Eau	DRINK	0	\N	EAU	t	2026-10-20 15:03:07.892686+00	2026-10-20 15:03:07.892693+00
bc1e03a7-e276-4da7-8f57-34d6d901bdb7	Boissons chaudes et desserts	DRINK	0	\N	AUTRES	t	2026-10-20 15:03:07.903966+00	2026-10-20 15:03:07.903975+00
725977b4-b95d-4b97-8979-c9b03b716e54	Suppléments	FOOD	0	\N	PLATS	t	2026-10-20 15:03:07.836677+00	2026-10-23 11:54:26.713169+00
\.


--
-- Data for Name: categories_depense; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.categories_depense (id, libelle, description) FROM stdin;
7	Achats Marchandises	Achats de réapprovisionnement direct
8	Transport & Logistique	Frais de transport et livraison
9	Énergie & Carburant	Carburant groupe électrogène, électricité
10	Fournitures & Emballages	Sachets, rouleaux thermiques, fournitures de bureau
11	Maintenance & Entretien	Réparations matériels et locaux
12	Frais Généraux Divers	Autres menues dépenses d'exploitation
13	Frais Généraux	Factures eau, électricité, entretien
14	Alimentation & Pause	Collations et repas équipe
15	Divers & Menues Dépenses	Dépenses imprévues sous autorisation
\.


--
-- Data for Name: customers; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.customers (id, name, ncc, phone, email, address, is_active, created_at, updated_at, tax_regime) FROM stdin;
a6e273be-5851-421a-96f2-a5b56ee678d1	CONFEDERATION GENERALE DES ENTREPRISES	1254632A	0767639874	main.9235@gmail.com	Abidjan, plateau	t	2026-10-03 16:59:11.864479+00	2026-10-03 16:59:11.86449+00	B2B
c10971e6-af3a-444f-806d-419be5fc06c8	AGL GRP	9506466A	0123546987	agl.grp@live.com	Abidjan, treichville	t	2026-10-05 10:40:41.897052+00	2026-10-05 10:40:41.897063+00	B2B
\.


--
-- Data for Name: daily_preparations; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.daily_preparations (id, business_date, article_id, prepared_quantity, yield_portions_per_unit, theoretical_dishes, user_id, notes, created_at, updated_at) FROM stdin;
2d59ce92-bf91-4967-b039-f51a63698ee7	2026-10-29	0e520485-53a3-403a-8dc8-547417bb83e4	6.000	1.00	6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	Auto-validé à la clôture de caisse	2026-10-29 16:36:46.086861+00	2026-10-29 16:36:46.086872+00
a56d71b4-1587-427e-9657-07fc48778071	2026-10-29	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.860	3.50	3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	Auto-validé à la clôture de caisse	2026-10-29 16:36:46.086882+00	2026-10-29 16:36:46.086885+00
20b0a3dc-6977-4166-881c-8f10029e3e8f	2026-10-29	8353e03f-35a0-44f9-ad7a-5c4336f90725	2.000	4.00	8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	Auto-validé à la clôture de caisse	2026-10-29 16:36:46.086893+00	2026-10-29 16:36:46.086897+00
2ddf3d25-70ae-48df-ae61-48c24e01a485	2026-10-29	a4cbfa56-e146-4cec-b536-34c376c34e28	7.000	1.00	7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	Auto-validé à la clôture de caisse	2026-10-29 16:36:46.086904+00	2026-10-29 16:36:46.086907+00
c3b68453-226d-4ad2-8839-4758450ffed9	2026-10-29	ebb5f404-2267-4fa1-bd71-dd9e54707294	1.800	5.00	9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	Auto-validé à la clôture de caisse	2026-10-29 16:36:46.086914+00	2026-10-29 16:36:46.086917+00
\.


--
-- Data for Name: denominations; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.denominations (id, valeur, type, actif) FROM stdin;
1	10000.00	billet	t
2	5000.00	billet	t
3	2000.00	billet	t
4	1000.00	billet	t
5	500.00	billet	t
6	250.00	piece	t
7	200.00	piece	t
8	100.00	piece	t
9	50.00	piece	t
10	25.00	piece	t
11	10.00	piece	t
12	5.00	piece	t
\.


--
-- Data for Name: establishment_settings; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.establishment_settings (id, restaurant_name, ncc, rccm, address, phone, default_vat_rate, receipt_footer, print_width, screen_lock_timeout_seconds, created_at, updated_at) FROM stdin;
81240c51-28c2-4215-afe8-15f79b6d390c	Sylla Plus	1234567A	CI-ABJ-2026-B-0000	Abidjan, Plateau	+225 0102030405	0	Merci de votre visite · à très bientôt !	58	120	2026-10-03 16:16:26.66162+00	2026-10-08 16:40:21.7769+00
\.


--
-- Data for Name: fne_documents; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.fne_documents (id, order_id, customer_id, document_type, status, invoice_number, qr_url, fne_token, payload, response_payload, error_message, retry_count, submitted_at, certified_at, created_at, updated_at, type, template, cash_session_id, parent_document_id, fne_invoice_id, items_map, fne_amount_ttc_xof, sticker_balance, is_uncertain, created_by_user_id, external_number, qr_payload, raw_response, attempts, last_error, next_retry_at) FROM stdin;
\.


--
-- Data for Name: fournisseurs; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.fournisseurs (id, nom, contact, telephone, actif) FROM stdin;
1	COQUIVOIRE	M. Kouassi	+225 0707070701	t
2	DKT INTERNATIONAL	Service Commercial	+225 0505050502	t
3	SODIREP	Mme Bamba	+225 0101010103	t
4	NESTLE CI	Distribution Abidjan	+225 2727272704	t
\.


--
-- Data for Name: idempotency_records; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.idempotency_records (key, request_path, request_hash, response_status, response_body, created_at, updated_at) FROM stdin;
session-open-1793272212896-30aeeb86-d7d3-42d6-8963-f3b360a5099c	/api/v1/cash-sessions	3bc3cfc862e961c7288a49b58735e8480538fc5551a941701b90f598a6b72e53	201	{"id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "cash_register_id": "caisse-01", "business_date": "2026-10-29", "status": "OPEN", "opening_float_xof": 100000, "opened_at": "2026-10-29T11:10:12.922192+00:00", "closed_at": null, "z_number": null, "expected_cash_xof": null, "counted_cash_xof": null, "variance_xof": null, "totals_snapshot": null}	2026-10-29 11:10:12.933693+00	2026-10-29 11:10:12.933703+00
item-add-1793289088724-0735f26d-b235-4b89-8368-8f0f2bb0118d	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	906713a206cc95f01ec6460ca3fabafb0c8c2c0fe0eb91cf14538684d72c349f	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 3000, "total_ht_xof": 3000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 3000, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:28.858207+00	2026-10-29 15:51:28.858217+00
item-add-1793289088873-740de11b-ce68-4936-93db-1ebf6d28fcc0	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	e9aa87b5ddd3cc9a8db8fccbb72ec742671fd68f3ef03af6898e10b1d100f763	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 6500, "total_ht_xof": 6500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 6500, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}, {"id": "fe43491c-8379-4c80-9019-4980d9ea4046", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:28.951814+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:28.973674+00	2026-10-29 15:51:28.973689+00
item-add-1793289089012-0db8d44a-1337-408f-8faa-68493e750e7e	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	a2719190dd24ee3b0261be57163d80d46fb11ff89ae652dec570417209d8c720	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 9500, "total_ht_xof": 9500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 9500, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}, {"id": "fe43491c-8379-4c80-9019-4980d9ea4046", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:28.951814+00:00", "removed_at": null, "removal_reason": null}, {"id": "b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.068179+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:29.086953+00	2026-10-29 15:51:29.086965+00
item-add-1793289089136-6d57ddff-5d4a-4fcc-a99a-ac5f7a5d9e9e	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	3684ec2387cfad9c06f812755b222e6c21690b5f391dc073baa1572e86039c10	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 12500, "total_ht_xof": 12500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 12500, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}, {"id": "fe43491c-8379-4c80-9019-4980d9ea4046", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:28.951814+00:00", "removed_at": null, "removal_reason": null}, {"id": "b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.068179+00:00", "removed_at": null, "removal_reason": null}, {"id": "f6516bfe-a30a-4469-a223-235df3a1cf4f", "product_id": "3b88851d-6135-478b-ae23-72cdc60db21c", "product_name_snapshot": "Kabato Dah + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.187982+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:29.202638+00	2026-10-29 15:51:29.202644+00
item-add-1793289089247-ae756357-f304-4519-98ce-925fc1a74efb	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	d58509eddeae5998b872637cdde5f817f8f86cfd12ec0f9e5ed512286f8ff3d8	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 15500, "total_ht_xof": 15500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 15500, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}, {"id": "fe43491c-8379-4c80-9019-4980d9ea4046", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:28.951814+00:00", "removed_at": null, "removal_reason": null}, {"id": "b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.068179+00:00", "removed_at": null, "removal_reason": null}, {"id": "f6516bfe-a30a-4469-a223-235df3a1cf4f", "product_id": "3b88851d-6135-478b-ae23-72cdc60db21c", "product_name_snapshot": "Kabato Dah + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.187982+00:00", "removed_at": null, "removal_reason": null}, {"id": "651ad9da-668d-41ca-98bd-fd5c693b36af", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.289532+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:29.305308+00	2026-10-29 15:51:29.305323+00
item-add-1793289089340-e0c3ce45-9f34-42a3-b0b5-d94b4b5938b1	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	1a314cbbc68870a935c859d1843d4d17f793daf2af53940dd63278cade36a9ab	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 18500, "total_ht_xof": 18500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 18500, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}, {"id": "fe43491c-8379-4c80-9019-4980d9ea4046", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:28.951814+00:00", "removed_at": null, "removal_reason": null}, {"id": "b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.068179+00:00", "removed_at": null, "removal_reason": null}, {"id": "f6516bfe-a30a-4469-a223-235df3a1cf4f", "product_id": "3b88851d-6135-478b-ae23-72cdc60db21c", "product_name_snapshot": "Kabato Dah + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.187982+00:00", "removed_at": null, "removal_reason": null}, {"id": "651ad9da-668d-41ca-98bd-fd5c693b36af", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.289532+00:00", "removed_at": null, "removal_reason": null}, {"id": "c33981ba-c745-446d-99bd-efccdca207da", "product_id": "46a09e73-28f4-4df9-984a-95ac939cfe1a", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Poulet", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.390459+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:29.410502+00	2026-10-29 15:51:29.410512+00
item-add-1793289089447-a4d65ea6-518a-4e57-951e-d09cbc3f9903	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	2cfb689b8ad3e5674f5c78a45ed26eb821e7e22168fb05d88dd06072ee8d5f4e	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 23500, "total_ht_xof": 23500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 23500, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}, {"id": "fe43491c-8379-4c80-9019-4980d9ea4046", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:28.951814+00:00", "removed_at": null, "removal_reason": null}, {"id": "b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.068179+00:00", "removed_at": null, "removal_reason": null}, {"id": "f6516bfe-a30a-4469-a223-235df3a1cf4f", "product_id": "3b88851d-6135-478b-ae23-72cdc60db21c", "product_name_snapshot": "Kabato Dah + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.187982+00:00", "removed_at": null, "removal_reason": null}, {"id": "651ad9da-668d-41ca-98bd-fd5c693b36af", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.289532+00:00", "removed_at": null, "removal_reason": null}, {"id": "c33981ba-c745-446d-99bd-efccdca207da", "product_id": "46a09e73-28f4-4df9-984a-95ac939cfe1a", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Poulet", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.390459+00:00", "removed_at": null, "removal_reason": null}, {"id": "4d790f5e-2f4b-4210-b0a6-eefb52b3e773", "product_id": "28e30eaa-c921-4371-8e7e-f0c7d3d1e011", "product_name_snapshot": "Alloco + Poisson brais\\u00e9", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 5000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 5000, "note": null, "added_at": "2026-10-29T15:51:29.496034+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:29.509466+00	2026-10-29 15:51:29.509477+00
item-add-1793289124808-4a8276a8-a31a-4859-86b6-ea8f4f0f571b	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/items	80f5262ce1f75f63c4a681ed3ffb99c312dc81aaa55a1dc60687b88b021ffcf1	200	{"id": "4df61102-c27c-4879-8ed2-15b88304cd09", "order_number": "2026-10-29-0002", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 2", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 25000, "total_ht_xof": 25000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 25000, "items": [{"id": "c03f81d8-1777-4c8b-9c91-8c0690d4555a", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.196660+00:00", "removed_at": null, "removal_reason": null}, {"id": "b033f55d-efa9-4237-bbcc-a0a118c42d13", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.294964+00:00", "removed_at": null, "removal_reason": null}, {"id": "32cf20d8-7aad-47df-a0bd-9577a68f574c", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.402631+00:00", "removed_at": null, "removal_reason": null}, {"id": "b0d9289b-e7f3-44f7-9bc4-2caad7472828", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.491957+00:00", "removed_at": null, "removal_reason": null}, {"id": "bb293b3e-c92f-49b7-9263-6bab906285f9", "product_id": "dbf93f42-7b4c-4c7e-a873-10f18a2151b0", "product_name_snapshot": "Igname frite + Mouton", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.578479+00:00", "removed_at": null, "removal_reason": null}, {"id": "023cf862-5641-4a2e-b690-00429131a979", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.666432+00:00", "removed_at": null, "removal_reason": null}, {"id": "b3526943-6b8d-4a08-9516-18f61ad84c12", "product_id": "1dcc3350-2fdb-4653-a60f-ec1212bb682e", "product_name_snapshot": "Alloco + Poulet", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.754228+00:00", "removed_at": null, "removal_reason": null}, {"id": "88811e0e-bea9-4939-a16d-7456e20b1d2e", "product_id": "e328a67e-40df-4b18-903d-a5938ad83d56", "product_name_snapshot": "Petit pois + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.837171+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:48.420750+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:52:04.849715+00	2026-10-29 15:52:04.84972+00
item-add-1793289089563-d244d4b9-04c8-4763-94ab-2c37026666a4	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	80f5262ce1f75f63c4a681ed3ffb99c312dc81aaa55a1dc60687b88b021ffcf1	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 26500, "total_ht_xof": 26500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 26500, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}, {"id": "fe43491c-8379-4c80-9019-4980d9ea4046", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:28.951814+00:00", "removed_at": null, "removal_reason": null}, {"id": "b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.068179+00:00", "removed_at": null, "removal_reason": null}, {"id": "f6516bfe-a30a-4469-a223-235df3a1cf4f", "product_id": "3b88851d-6135-478b-ae23-72cdc60db21c", "product_name_snapshot": "Kabato Dah + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.187982+00:00", "removed_at": null, "removal_reason": null}, {"id": "651ad9da-668d-41ca-98bd-fd5c693b36af", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.289532+00:00", "removed_at": null, "removal_reason": null}, {"id": "c33981ba-c745-446d-99bd-efccdca207da", "product_id": "46a09e73-28f4-4df9-984a-95ac939cfe1a", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Poulet", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.390459+00:00", "removed_at": null, "removal_reason": null}, {"id": "4d790f5e-2f4b-4210-b0a6-eefb52b3e773", "product_id": "28e30eaa-c921-4371-8e7e-f0c7d3d1e011", "product_name_snapshot": "Alloco + Poisson brais\\u00e9", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 5000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 5000, "note": null, "added_at": "2026-10-29T15:51:29.496034+00:00", "removed_at": null, "removal_reason": null}, {"id": "2529e749-aa73-40b1-9478-8e0738879f53", "product_id": "e328a67e-40df-4b18-903d-a5938ad83d56", "product_name_snapshot": "Petit pois + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.601496+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:29.614874+00	2026-10-29 15:51:29.614881+00
item-add-1793289089680-605c221d-0770-471f-b27b-2bacb5ed4a74	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/items	b37da42af1dd90c247bebe3bcf1f74234c944709028ef1d8c37f61893ded5193	200	{"id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "order_number": "2026-10-29-0001", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 30000, "total_ht_xof": 30000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 30000, "items": [{"id": "886a1abb-1324-4132-ab3d-d85de26466f7", "product_id": "934dde37-9033-45e6-86ed-7cdd2215b18e", "product_name_snapshot": "Kabato Dah + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:28.782276+00:00", "removed_at": null, "removal_reason": null}, {"id": "fe43491c-8379-4c80-9019-4980d9ea4046", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:28.951814+00:00", "removed_at": null, "removal_reason": null}, {"id": "b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.068179+00:00", "removed_at": null, "removal_reason": null}, {"id": "f6516bfe-a30a-4469-a223-235df3a1cf4f", "product_id": "3b88851d-6135-478b-ae23-72cdc60db21c", "product_name_snapshot": "Kabato Dah + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.187982+00:00", "removed_at": null, "removal_reason": null}, {"id": "651ad9da-668d-41ca-98bd-fd5c693b36af", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.289532+00:00", "removed_at": null, "removal_reason": null}, {"id": "c33981ba-c745-446d-99bd-efccdca207da", "product_id": "46a09e73-28f4-4df9-984a-95ac939cfe1a", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Poulet", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.390459+00:00", "removed_at": null, "removal_reason": null}, {"id": "4d790f5e-2f4b-4210-b0a6-eefb52b3e773", "product_id": "28e30eaa-c921-4371-8e7e-f0c7d3d1e011", "product_name_snapshot": "Alloco + Poisson brais\\u00e9", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 5000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 5000, "note": null, "added_at": "2026-10-29T15:51:29.496034+00:00", "removed_at": null, "removal_reason": null}, {"id": "2529e749-aa73-40b1-9478-8e0738879f53", "product_id": "e328a67e-40df-4b18-903d-a5938ad83d56", "product_name_snapshot": "Petit pois + B\\u0153uf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:51:29.601496+00:00", "removed_at": null, "removal_reason": null}, {"id": "b5f69c09-9d24-4966-82fc-2f95a163bfb1", "product_id": "4f4a6067-f359-4422-bbbb-20f5aaded6b3", "product_name_snapshot": "Petit pois + Sosso 3500", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:51:29.719530+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:28.643693+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:51:29.733412+00	2026-10-29 15:51:29.733419+00
item-add-1793289124167-8549d4af-c492-4873-98d5-2634c204283b	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/items	904c7965f4c089c5182e2721188220e282bfa2feab8e2010b0a3a2619cd5e4a2	200	{"id": "4df61102-c27c-4879-8ed2-15b88304cd09", "order_number": "2026-10-29-0002", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 2", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 3000, "total_ht_xof": 3000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 3000, "items": [{"id": "c03f81d8-1777-4c8b-9c91-8c0690d4555a", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.196660+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:48.420750+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:52:04.207624+00	2026-10-29 15:52:04.207631+00
item-add-1793289124258-cf584fe1-5de3-40e9-a2ff-640f7dc019c2	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/items	e9aa87b5ddd3cc9a8db8fccbb72ec742671fd68f3ef03af6898e10b1d100f763	200	{"id": "4df61102-c27c-4879-8ed2-15b88304cd09", "order_number": "2026-10-29-0002", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 2", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 6500, "total_ht_xof": 6500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 6500, "items": [{"id": "c03f81d8-1777-4c8b-9c91-8c0690d4555a", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.196660+00:00", "removed_at": null, "removal_reason": null}, {"id": "b033f55d-efa9-4237-bbcc-a0a118c42d13", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.294964+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:48.420750+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:52:04.308544+00	2026-10-29 15:52:04.30856+00
item-add-1793289124369-32c02c96-7005-4507-9c02-dc9621164551	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/items	a2719190dd24ee3b0261be57163d80d46fb11ff89ae652dec570417209d8c720	200	{"id": "4df61102-c27c-4879-8ed2-15b88304cd09", "order_number": "2026-10-29-0002", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 2", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 9500, "total_ht_xof": 9500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 9500, "items": [{"id": "c03f81d8-1777-4c8b-9c91-8c0690d4555a", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.196660+00:00", "removed_at": null, "removal_reason": null}, {"id": "b033f55d-efa9-4237-bbcc-a0a118c42d13", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.294964+00:00", "removed_at": null, "removal_reason": null}, {"id": "32cf20d8-7aad-47df-a0bd-9577a68f574c", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.402631+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:48.420750+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:52:04.418116+00	2026-10-29 15:52:04.418128+00
item-add-1793289124457-3a203ce4-a8f0-44d0-9567-a95942dc2dd4	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/items	d58509eddeae5998b872637cdde5f817f8f86cfd12ec0f9e5ed512286f8ff3d8	200	{"id": "4df61102-c27c-4879-8ed2-15b88304cd09", "order_number": "2026-10-29-0002", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 2", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 12500, "total_ht_xof": 12500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 12500, "items": [{"id": "c03f81d8-1777-4c8b-9c91-8c0690d4555a", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.196660+00:00", "removed_at": null, "removal_reason": null}, {"id": "b033f55d-efa9-4237-bbcc-a0a118c42d13", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.294964+00:00", "removed_at": null, "removal_reason": null}, {"id": "32cf20d8-7aad-47df-a0bd-9577a68f574c", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.402631+00:00", "removed_at": null, "removal_reason": null}, {"id": "b0d9289b-e7f3-44f7-9bc4-2caad7472828", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.491957+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:48.420750+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:52:04.506291+00	2026-10-29 15:52:04.506301+00
item-add-1793289124544-69045df3-762e-438c-98d4-ddf508f4a417	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/items	f3bffb865d567edbc66a88bc69c2443c7f5e1efc743ad01b811ae05efe57f0e1	200	{"id": "4df61102-c27c-4879-8ed2-15b88304cd09", "order_number": "2026-10-29-0002", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 2", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 16000, "total_ht_xof": 16000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 16000, "items": [{"id": "c03f81d8-1777-4c8b-9c91-8c0690d4555a", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.196660+00:00", "removed_at": null, "removal_reason": null}, {"id": "b033f55d-efa9-4237-bbcc-a0a118c42d13", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.294964+00:00", "removed_at": null, "removal_reason": null}, {"id": "32cf20d8-7aad-47df-a0bd-9577a68f574c", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.402631+00:00", "removed_at": null, "removal_reason": null}, {"id": "b0d9289b-e7f3-44f7-9bc4-2caad7472828", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.491957+00:00", "removed_at": null, "removal_reason": null}, {"id": "bb293b3e-c92f-49b7-9263-6bab906285f9", "product_id": "dbf93f42-7b4c-4c7e-a873-10f18a2151b0", "product_name_snapshot": "Igname frite + Mouton", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.578479+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:48.420750+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:52:04.589966+00	2026-10-29 15:52:04.589975+00
item-add-1793289124633-f637b56d-2acd-47f0-8bc5-9a38a2c9345b	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/items	e8007ba644c6062917820682e9ee770a5ebce93f1a501c925cf1da576a0d7f22	200	{"id": "4df61102-c27c-4879-8ed2-15b88304cd09", "order_number": "2026-10-29-0002", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 2", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 19000, "total_ht_xof": 19000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 19000, "items": [{"id": "c03f81d8-1777-4c8b-9c91-8c0690d4555a", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.196660+00:00", "removed_at": null, "removal_reason": null}, {"id": "b033f55d-efa9-4237-bbcc-a0a118c42d13", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.294964+00:00", "removed_at": null, "removal_reason": null}, {"id": "32cf20d8-7aad-47df-a0bd-9577a68f574c", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.402631+00:00", "removed_at": null, "removal_reason": null}, {"id": "b0d9289b-e7f3-44f7-9bc4-2caad7472828", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.491957+00:00", "removed_at": null, "removal_reason": null}, {"id": "bb293b3e-c92f-49b7-9263-6bab906285f9", "product_id": "dbf93f42-7b4c-4c7e-a873-10f18a2151b0", "product_name_snapshot": "Igname frite + Mouton", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.578479+00:00", "removed_at": null, "removal_reason": null}, {"id": "023cf862-5641-4a2e-b690-00429131a979", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.666432+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:48.420750+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:52:04.678376+00	2026-10-29 15:52:04.678384+00
item-add-1793289124723-99ea6ffb-a434-40bb-8444-4b4abc279af1	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/items	adfbffd709bbf552de0a0b6516b12b3f1839496e469ec2ff36de6c03a3bd97d9	200	{"id": "4df61102-c27c-4879-8ed2-15b88304cd09", "order_number": "2026-10-29-0002", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 2", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 22000, "total_ht_xof": 22000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 22000, "items": [{"id": "c03f81d8-1777-4c8b-9c91-8c0690d4555a", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.196660+00:00", "removed_at": null, "removal_reason": null}, {"id": "b033f55d-efa9-4237-bbcc-a0a118c42d13", "product_id": "2c470520-ac57-4c94-bc51-2e952fe1ab21", "product_name_snapshot": "Kabato Dah + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.294964+00:00", "removed_at": null, "removal_reason": null}, {"id": "32cf20d8-7aad-47df-a0bd-9577a68f574c", "product_id": "f8c3551b-ce83-449e-a6c1-a640f89e8e68", "product_name_snapshot": "Kabato Kope + Poisson", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.402631+00:00", "removed_at": null, "removal_reason": null}, {"id": "b0d9289b-e7f3-44f7-9bc4-2caad7472828", "product_id": "e2551239-6d21-4a43-aac3-f435b261884e", "product_name_snapshot": "Frites + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.491957+00:00", "removed_at": null, "removal_reason": null}, {"id": "bb293b3e-c92f-49b7-9263-6bab906285f9", "product_id": "dbf93f42-7b4c-4c7e-a873-10f18a2151b0", "product_name_snapshot": "Igname frite + Mouton", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T15:52:04.578479+00:00", "removed_at": null, "removal_reason": null}, {"id": "023cf862-5641-4a2e-b690-00429131a979", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.666432+00:00", "removed_at": null, "removal_reason": null}, {"id": "b3526943-6b8d-4a08-9516-18f61ad84c12", "product_id": "1dcc3350-2fdb-4653-a60f-ec1212bb682e", "product_name_snapshot": "Alloco + Poulet", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T15:52:04.754228+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T15:51:48.420750+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 15:52:04.766864+00	2026-10-29 15:52:04.766872+00
pay-03f1433e-f79b-47f1-923c-55a1b3061ef8-1793289161573-ef3m3pb	/api/v1/orders/03f1433e-f79b-47f1-923c-55a1b3061ef8/payments	9ff1a83fc9b79c61f6e2fe9c8f46a0d32bfcd50ebb1a7525efa7ddedb53b0aab	201	{"payment": {"id": "36ef37f6-2243-41bf-b2bf-e6a4f04c251b", "order_id": "03f1433e-f79b-47f1-923c-55a1b3061ef8", "method": "CASH", "amount_xof": 30000, "tendered_xof": 30000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-29T15:52:41.618147+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "d2f9eca5-d91c-417b-800c-b74f1354e0a4", "fne_status": null, "warnings": []}	2026-10-29 15:52:41.721542+00	2026-10-29 15:52:41.721553+00
pay-4df61102-c27c-4879-8ed2-15b88304cd09-1793289225842-1dags7e	/api/v1/orders/4df61102-c27c-4879-8ed2-15b88304cd09/payments	7db2e41c771755f9f96db7bbd180dc25d262e04866a868b500f9346807088a6c	201	{"payment": {"id": "af169dc1-29a2-4501-8f71-1bbe83177f2e", "order_id": "4df61102-c27c-4879-8ed2-15b88304cd09", "method": "CASH", "amount_xof": 25000, "tendered_xof": 25000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-29T15:53:45.885314+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "a852790d-f472-4836-aab8-56a0e88ba550", "fne_status": null, "warnings": []}	2026-10-29 15:53:45.931212+00	2026-10-29 15:53:45.931222+00
item-add-1793291592932-37b1c9a0-ebb1-4f72-92d3-f33cc4cdb11b	/api/v1/orders/786345a5-e9b2-4ac6-89f4-4397ba8b4fa7/items	6d42f4c6181f6425eb6adf6339ed2b790b4bf9d2a9006b7ac11cf91db1cdb57c	200	{"id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "order_number": "2026-10-29-0003", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "table_label": "Table 2", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 4000, "total_ht_xof": 4000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 4000, "items": [{"id": "52cacaa5-7d53-41fe-8e84-616f049e5043", "product_id": "fae9bc78-c632-44ec-a196-9e9f7f970fa0", "product_name_snapshot": "Igname bouillie + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.002438+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:12.848838+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:13.031625+00	2026-10-29 16:33:13.031638+00
item-add-1793291624698-0a28b115-c183-4ded-9cfd-f3296b3c0964	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	24f2b28a4196be1a682465e3b2d335f3e2a529b136de3914817b3bfe65225943	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 3500, "total_ht_xof": 3500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 3500, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:44.759186+00	2026-10-29 16:33:44.759197+00
item-add-1793291593077-9c1e2f7a-4d93-4e68-8b8b-4dbcef6f4bb0	/api/v1/orders/786345a5-e9b2-4ac6-89f4-4397ba8b4fa7/items	e8007ba644c6062917820682e9ee770a5ebce93f1a501c925cf1da576a0d7f22	200	{"id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "order_number": "2026-10-29-0003", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "table_label": "Table 2", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 7000, "total_ht_xof": 7000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 7000, "items": [{"id": "52cacaa5-7d53-41fe-8e84-616f049e5043", "product_id": "fae9bc78-c632-44ec-a196-9e9f7f970fa0", "product_name_snapshot": "Igname bouillie + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.002438+00:00", "removed_at": null, "removal_reason": null}, {"id": "5884e7fb-f015-4316-8833-f3da0c3ddeed", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.124249+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:12.848838+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:13.145925+00	2026-10-29 16:33:13.145936+00
item-add-1793291593208-2e130e31-e72d-4a56-854b-c2d30b21f6d6	/api/v1/orders/786345a5-e9b2-4ac6-89f4-4397ba8b4fa7/items	75482511173319ef66e2a8b68bf0ea543d0846ac628fb82362d62d73671f72f1	200	{"id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "order_number": "2026-10-29-0003", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "table_label": "Table 2", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 11000, "total_ht_xof": 11000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 11000, "items": [{"id": "52cacaa5-7d53-41fe-8e84-616f049e5043", "product_id": "fae9bc78-c632-44ec-a196-9e9f7f970fa0", "product_name_snapshot": "Igname bouillie + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.002438+00:00", "removed_at": null, "removal_reason": null}, {"id": "5884e7fb-f015-4316-8833-f3da0c3ddeed", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.124249+00:00", "removed_at": null, "removal_reason": null}, {"id": "53813ee6-0602-4f66-88d0-bb3079b78275", "product_id": "7e2e9acc-4cb0-4222-8e04-e09402820956", "product_name_snapshot": "Alloco + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.245798+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:12.848838+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:13.263886+00	2026-10-29 16:33:13.263899+00
item-add-1793291593327-05ad040c-d82b-4a4c-b83c-adf7523f42da	/api/v1/orders/786345a5-e9b2-4ac6-89f4-4397ba8b4fa7/items	88d26788183989c77a5ba0d02332efaebfab040ace6114631cc8d550605ceca0	200	{"id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "order_number": "2026-10-29-0003", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "table_label": "Table 2", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 14000, "total_ht_xof": 14000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 14000, "items": [{"id": "52cacaa5-7d53-41fe-8e84-616f049e5043", "product_id": "fae9bc78-c632-44ec-a196-9e9f7f970fa0", "product_name_snapshot": "Igname bouillie + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.002438+00:00", "removed_at": null, "removal_reason": null}, {"id": "5884e7fb-f015-4316-8833-f3da0c3ddeed", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.124249+00:00", "removed_at": null, "removal_reason": null}, {"id": "53813ee6-0602-4f66-88d0-bb3079b78275", "product_id": "7e2e9acc-4cb0-4222-8e04-e09402820956", "product_name_snapshot": "Alloco + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.245798+00:00", "removed_at": null, "removal_reason": null}, {"id": "10da25f8-2495-4165-b908-37c7fd9f821b", "product_id": "da7a9d7b-64d7-46e9-9a66-fb411d1976e5", "product_name_snapshot": "Salade Panach\\u00e9e + Poulet", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.398427+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:12.848838+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:13.414333+00	2026-10-29 16:33:13.414364+00
item-add-1793291593461-8637a394-bb11-4e31-ad05-818d58017762	/api/v1/orders/786345a5-e9b2-4ac6-89f4-4397ba8b4fa7/items	f6840a534007075d3c30598c3018ca12a26348f5b028ddcb2d8affc363fbcfad	200	{"id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "order_number": "2026-10-29-0003", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "table_label": "Table 2", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 17000, "total_ht_xof": 17000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 17000, "items": [{"id": "52cacaa5-7d53-41fe-8e84-616f049e5043", "product_id": "fae9bc78-c632-44ec-a196-9e9f7f970fa0", "product_name_snapshot": "Igname bouillie + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.002438+00:00", "removed_at": null, "removal_reason": null}, {"id": "5884e7fb-f015-4316-8833-f3da0c3ddeed", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.124249+00:00", "removed_at": null, "removal_reason": null}, {"id": "53813ee6-0602-4f66-88d0-bb3079b78275", "product_id": "7e2e9acc-4cb0-4222-8e04-e09402820956", "product_name_snapshot": "Alloco + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.245798+00:00", "removed_at": null, "removal_reason": null}, {"id": "10da25f8-2495-4165-b908-37c7fd9f821b", "product_id": "da7a9d7b-64d7-46e9-9a66-fb411d1976e5", "product_name_snapshot": "Salade Panach\\u00e9e + Poulet", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.398427+00:00", "removed_at": null, "removal_reason": null}, {"id": "6b6248ae-cd37-4b18-a89b-f73c403b9622", "product_id": "9730e484-0913-497b-8663-b228822b3ddc", "product_name_snapshot": "Salade Fra\\u00eeche + Poulet", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.504952+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:12.848838+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:13.523546+00	2026-10-29 16:33:13.523556+00
item-add-1793291593572-0852f21c-30ff-4324-846b-a8c0dfbbf9cb	/api/v1/orders/786345a5-e9b2-4ac6-89f4-4397ba8b4fa7/items	1a2b004967f5c747eba90acc1007522bdc337e94e1db1d72c249de9daab37d01	200	{"id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "order_number": "2026-10-29-0003", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "table_label": "Table 2", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 21000, "total_ht_xof": 21000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 21000, "items": [{"id": "52cacaa5-7d53-41fe-8e84-616f049e5043", "product_id": "fae9bc78-c632-44ec-a196-9e9f7f970fa0", "product_name_snapshot": "Igname bouillie + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.002438+00:00", "removed_at": null, "removal_reason": null}, {"id": "5884e7fb-f015-4316-8833-f3da0c3ddeed", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.124249+00:00", "removed_at": null, "removal_reason": null}, {"id": "53813ee6-0602-4f66-88d0-bb3079b78275", "product_id": "7e2e9acc-4cb0-4222-8e04-e09402820956", "product_name_snapshot": "Alloco + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.245798+00:00", "removed_at": null, "removal_reason": null}, {"id": "10da25f8-2495-4165-b908-37c7fd9f821b", "product_id": "da7a9d7b-64d7-46e9-9a66-fb411d1976e5", "product_name_snapshot": "Salade Panach\\u00e9e + Poulet", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.398427+00:00", "removed_at": null, "removal_reason": null}, {"id": "6b6248ae-cd37-4b18-a89b-f73c403b9622", "product_id": "9730e484-0913-497b-8663-b228822b3ddc", "product_name_snapshot": "Salade Fra\\u00eeche + Poulet", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.504952+00:00", "removed_at": null, "removal_reason": null}, {"id": "a36043cf-1af4-4f12-a5d3-28386af12cdc", "product_id": "93b1f693-b2ca-4ca6-8abd-bbd9abcfd971", "product_name_snapshot": "Salade Fra\\u00eeche + Sosso 4000", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.620768+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:12.848838+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:13.638152+00	2026-10-29 16:33:13.638166+00
item-add-1793291593685-e05d2f11-4e3d-461e-b788-ce7ce36f07ae	/api/v1/orders/786345a5-e9b2-4ac6-89f4-4397ba8b4fa7/items	4550ed7a9a1e1f1e83904d4d6069a6b1c58bde8818aa7cb635886ddee672a603	200	{"id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "order_number": "2026-10-29-0003", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "table_label": "Table 2", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 26000, "total_ht_xof": 26000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 26000, "items": [{"id": "52cacaa5-7d53-41fe-8e84-616f049e5043", "product_id": "fae9bc78-c632-44ec-a196-9e9f7f970fa0", "product_name_snapshot": "Igname bouillie + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.002438+00:00", "removed_at": null, "removal_reason": null}, {"id": "5884e7fb-f015-4316-8833-f3da0c3ddeed", "product_id": "fac18978-1efd-4b64-99a7-75758a3d73c6", "product_name_snapshot": "Atti\\u00e9k\\u00e9 + Boeuf", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.124249+00:00", "removed_at": null, "removal_reason": null}, {"id": "53813ee6-0602-4f66-88d0-bb3079b78275", "product_id": "7e2e9acc-4cb0-4222-8e04-e09402820956", "product_name_snapshot": "Alloco + Sosso", "category_snapshot": "Sp\\u00e9cial Ivoirienne", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.245798+00:00", "removed_at": null, "removal_reason": null}, {"id": "10da25f8-2495-4165-b908-37c7fd9f821b", "product_id": "da7a9d7b-64d7-46e9-9a66-fb411d1976e5", "product_name_snapshot": "Salade Panach\\u00e9e + Poulet", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.398427+00:00", "removed_at": null, "removal_reason": null}, {"id": "6b6248ae-cd37-4b18-a89b-f73c403b9622", "product_id": "9730e484-0913-497b-8663-b228822b3ddc", "product_name_snapshot": "Salade Fra\\u00eeche + Poulet", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:13.504952+00:00", "removed_at": null, "removal_reason": null}, {"id": "a36043cf-1af4-4f12-a5d3-28386af12cdc", "product_id": "93b1f693-b2ca-4ca6-8abd-bbd9abcfd971", "product_name_snapshot": "Salade Fra\\u00eeche + Sosso 4000", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:13.620768+00:00", "removed_at": null, "removal_reason": null}, {"id": "44233049-ad0f-420f-9fc7-c94a58dba425", "product_id": "df2a62c3-58d6-430f-b10e-45b0cb58cff1", "product_name_snapshot": "Salade Panach\\u00e9e + Sosso 5000", "category_snapshot": "Sp\\u00e9cial Salade", "unit_price_xof": 5000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 5000, "note": null, "added_at": "2026-10-29T16:33:13.731553+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:12.848838+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:13.748131+00	2026-10-29 16:33:13.748141+00
item-add-1793291625000-b63ce294-d251-4fbc-9654-ea38e88033c7	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	904c7965f4c089c5182e2721188220e282bfa2feab8e2010b0a3a2619cd5e4a2	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 13500, "total_ht_xof": 13500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 13500, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}, {"id": "1b32cc23-9ad8-4a45-97c9-fb91c0d24abb", "product_id": "93418cf7-cec2-4441-925a-2917ba67479a", "product_name_snapshot": "Sosso 7000", "category_snapshot": "Poissons", "unit_price_xof": 7000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 7000, "note": null, "added_at": "2026-10-29T16:33:44.890289+00:00", "removed_at": null, "removal_reason": null}, {"id": "ddc6864b-3904-41f3-9f3a-b791af71aedc", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.061905+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:45.080241+00	2026-10-29 16:33:45.080254+00
item-add-1793291625483-f064b162-cc34-4c49-a8b2-8eedf46f7f3e	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	659af238204e5b85a1991a48c4909613f3d4c6907f62f82a5d6ce2ecd2e0b423	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 26000, "total_ht_xof": 26000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 26000, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}, {"id": "1b32cc23-9ad8-4a45-97c9-fb91c0d24abb", "product_id": "93418cf7-cec2-4441-925a-2917ba67479a", "product_name_snapshot": "Sosso 7000", "category_snapshot": "Poissons", "unit_price_xof": 7000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 7000, "note": null, "added_at": "2026-10-29T16:33:44.890289+00:00", "removed_at": null, "removal_reason": null}, {"id": "ddc6864b-3904-41f3-9f3a-b791af71aedc", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.061905+00:00", "removed_at": null, "removal_reason": null}, {"id": "34a0bc05-7144-4cf4-b542-2edb6a271273", "product_id": "78a775c5-9a24-4760-a370-483ebc35cd3d", "product_name_snapshot": "Kabato Lafri + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.194067+00:00", "removed_at": null, "removal_reason": null}, {"id": "cf4f9468-9d80-4cd0-a28f-f3ea46ac8ff2", "product_id": "3acf88aa-9368-4a0b-a967-3e79d26c59dc", "product_name_snapshot": "Kabato Dah + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.323293+00:00", "removed_at": null, "removal_reason": null}, {"id": "db889a3d-91e0-478f-ba4e-e266bcdccd46", "product_id": "e187c501-7b39-497d-95d8-832d0aa0ac66", "product_name_snapshot": "Kabato Lafri + Mouton", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:45.425736+00:00", "removed_at": null, "removal_reason": null}, {"id": "8e61150a-5664-470a-8ae3-ee2f8a2bdb4d", "product_id": "19a0e1b1-b889-4cf6-b553-017f739929aa", "product_name_snapshot": "Couscous + Poulet", "category_snapshot": "Sp\\u00e9cial Oriental", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.540079+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:45.558247+00	2026-10-29 16:33:45.558258+00
item-add-1793291625704-c1443ca6-9155-4778-9440-3be44a28f0ea	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	7479bce506d93872169453ab40ef84cbe098f407db0ed2c95397f5337b999c60	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 33500, "total_ht_xof": 33500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 33500, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}, {"id": "1b32cc23-9ad8-4a45-97c9-fb91c0d24abb", "product_id": "93418cf7-cec2-4441-925a-2917ba67479a", "product_name_snapshot": "Sosso 7000", "category_snapshot": "Poissons", "unit_price_xof": 7000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 7000, "note": null, "added_at": "2026-10-29T16:33:44.890289+00:00", "removed_at": null, "removal_reason": null}, {"id": "ddc6864b-3904-41f3-9f3a-b791af71aedc", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.061905+00:00", "removed_at": null, "removal_reason": null}, {"id": "34a0bc05-7144-4cf4-b542-2edb6a271273", "product_id": "78a775c5-9a24-4760-a370-483ebc35cd3d", "product_name_snapshot": "Kabato Lafri + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.194067+00:00", "removed_at": null, "removal_reason": null}, {"id": "cf4f9468-9d80-4cd0-a28f-f3ea46ac8ff2", "product_id": "3acf88aa-9368-4a0b-a967-3e79d26c59dc", "product_name_snapshot": "Kabato Dah + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.323293+00:00", "removed_at": null, "removal_reason": null}, {"id": "db889a3d-91e0-478f-ba4e-e266bcdccd46", "product_id": "e187c501-7b39-497d-95d8-832d0aa0ac66", "product_name_snapshot": "Kabato Lafri + Mouton", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:45.425736+00:00", "removed_at": null, "removal_reason": null}, {"id": "8e61150a-5664-470a-8ae3-ee2f8a2bdb4d", "product_id": "19a0e1b1-b889-4cf6-b553-017f739929aa", "product_name_snapshot": "Couscous + Poulet", "category_snapshot": "Sp\\u00e9cial Oriental", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.540079+00:00", "removed_at": null, "removal_reason": null}, {"id": "3ff47e3f-82e6-45f4-8ae4-a4e854c07bcc", "product_id": "cd408593-401c-46d0-8507-624f0342f05a", "product_name_snapshot": "Couscous + Poisson", "category_snapshot": "Sp\\u00e9cial Oriental", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:45.637192+00:00", "removed_at": null, "removal_reason": null}, {"id": "96301ae0-6da5-4801-81e0-e95b2025e5c6", "product_id": "e2028931-16ad-47cd-a58c-03359d67788d", "product_name_snapshot": "Couscous + Mouton", "category_snapshot": "Sp\\u00e9cial Oriental", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-29T16:33:45.736705+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:45.756206+00	2026-10-29 16:33:45.756219+00
item-add-1793291624828-82593684-d2f5-45bf-8776-35606430a98a	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	959432f9aa52a447a6674573072607eb32289eef0d866737d1a29f0c55807e4d	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 10500, "total_ht_xof": 10500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 10500, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}, {"id": "1b32cc23-9ad8-4a45-97c9-fb91c0d24abb", "product_id": "93418cf7-cec2-4441-925a-2917ba67479a", "product_name_snapshot": "Sosso 7000", "category_snapshot": "Poissons", "unit_price_xof": 7000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 7000, "note": null, "added_at": "2026-10-29T16:33:44.890289+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:44.911082+00	2026-10-29 16:33:44.911095+00
item-add-1793291625160-4cb91181-900d-4e27-8675-166b01e4a36b	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	35968422dc8d33ce1d202c5de3de70bddbbfc1a07df0d8b51c2c1bf23d1d478a	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 16500, "total_ht_xof": 16500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 16500, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}, {"id": "1b32cc23-9ad8-4a45-97c9-fb91c0d24abb", "product_id": "93418cf7-cec2-4441-925a-2917ba67479a", "product_name_snapshot": "Sosso 7000", "category_snapshot": "Poissons", "unit_price_xof": 7000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 7000, "note": null, "added_at": "2026-10-29T16:33:44.890289+00:00", "removed_at": null, "removal_reason": null}, {"id": "ddc6864b-3904-41f3-9f3a-b791af71aedc", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.061905+00:00", "removed_at": null, "removal_reason": null}, {"id": "34a0bc05-7144-4cf4-b542-2edb6a271273", "product_id": "78a775c5-9a24-4760-a370-483ebc35cd3d", "product_name_snapshot": "Kabato Lafri + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.194067+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:45.210521+00	2026-10-29 16:33:45.21053+00
item-add-1793291625284-1851f181-cf43-4a11-acf6-2ebaaf86f37b	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	1ededbf3a6fff68915aa6a9215c1584ab27b93cd7040f2f9e95b56e54f3c59a8	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 19500, "total_ht_xof": 19500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 19500, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}, {"id": "1b32cc23-9ad8-4a45-97c9-fb91c0d24abb", "product_id": "93418cf7-cec2-4441-925a-2917ba67479a", "product_name_snapshot": "Sosso 7000", "category_snapshot": "Poissons", "unit_price_xof": 7000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 7000, "note": null, "added_at": "2026-10-29T16:33:44.890289+00:00", "removed_at": null, "removal_reason": null}, {"id": "ddc6864b-3904-41f3-9f3a-b791af71aedc", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.061905+00:00", "removed_at": null, "removal_reason": null}, {"id": "34a0bc05-7144-4cf4-b542-2edb6a271273", "product_id": "78a775c5-9a24-4760-a370-483ebc35cd3d", "product_name_snapshot": "Kabato Lafri + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.194067+00:00", "removed_at": null, "removal_reason": null}, {"id": "cf4f9468-9d80-4cd0-a28f-f3ea46ac8ff2", "product_id": "3acf88aa-9368-4a0b-a967-3e79d26c59dc", "product_name_snapshot": "Kabato Dah + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.323293+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:45.33922+00	2026-10-29 16:33:45.339232+00
item-add-1793291625604-c4bb402c-ef3b-4139-81fb-92eb77a15b6e	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	e8a6145cb9ffe4d0a7cd9803b36ab77bf647b5920d3f9072830302d14b948954	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 29500, "total_ht_xof": 29500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 29500, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}, {"id": "1b32cc23-9ad8-4a45-97c9-fb91c0d24abb", "product_id": "93418cf7-cec2-4441-925a-2917ba67479a", "product_name_snapshot": "Sosso 7000", "category_snapshot": "Poissons", "unit_price_xof": 7000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 7000, "note": null, "added_at": "2026-10-29T16:33:44.890289+00:00", "removed_at": null, "removal_reason": null}, {"id": "ddc6864b-3904-41f3-9f3a-b791af71aedc", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.061905+00:00", "removed_at": null, "removal_reason": null}, {"id": "34a0bc05-7144-4cf4-b542-2edb6a271273", "product_id": "78a775c5-9a24-4760-a370-483ebc35cd3d", "product_name_snapshot": "Kabato Lafri + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.194067+00:00", "removed_at": null, "removal_reason": null}, {"id": "cf4f9468-9d80-4cd0-a28f-f3ea46ac8ff2", "product_id": "3acf88aa-9368-4a0b-a967-3e79d26c59dc", "product_name_snapshot": "Kabato Dah + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.323293+00:00", "removed_at": null, "removal_reason": null}, {"id": "db889a3d-91e0-478f-ba4e-e266bcdccd46", "product_id": "e187c501-7b39-497d-95d8-832d0aa0ac66", "product_name_snapshot": "Kabato Lafri + Mouton", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:45.425736+00:00", "removed_at": null, "removal_reason": null}, {"id": "8e61150a-5664-470a-8ae3-ee2f8a2bdb4d", "product_id": "19a0e1b1-b889-4cf6-b553-017f739929aa", "product_name_snapshot": "Couscous + Poulet", "category_snapshot": "Sp\\u00e9cial Oriental", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.540079+00:00", "removed_at": null, "removal_reason": null}, {"id": "3ff47e3f-82e6-45f4-8ae4-a4e854c07bcc", "product_id": "cd408593-401c-46d0-8507-624f0342f05a", "product_name_snapshot": "Couscous + Poisson", "category_snapshot": "Sp\\u00e9cial Oriental", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:45.637192+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:45.652795+00	2026-10-29 16:33:45.652806+00
pay-786345a5-e9b2-4ac6-89f4-4397ba8b4fa7-1793291654272-jgzy9bm	/api/v1/orders/786345a5-e9b2-4ac6-89f4-4397ba8b4fa7/payments	4e62265c18bf436a269b33f497b4dc2ed8caf6017c5a4ffde8c4674c9db2399b	201	{"payment": {"id": "7aeb51d0-f90a-45b0-9577-87bb37396bb8", "order_id": "786345a5-e9b2-4ac6-89f4-4397ba8b4fa7", "method": "CASH", "amount_xof": 26000, "tendered_xof": 26000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-29T16:34:14.307852+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "eb25f8f8-8b25-4cc3-a4f2-c3d2885fab9a", "fne_status": null, "warnings": []}	2026-10-29 16:34:14.362407+00	2026-10-29 16:34:14.362417+00
session-close-1793291805983-7fa97ea8-bcb8-4785-9754-15d0010095fb	/api/v1/cash-sessions/43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a/close	96e08c2412bd116be560576ccc509a1f529c17a781c737f32fcf5d5c0e98da4a	200	{"id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "cash_register_id": "caisse-01", "business_date": "2026-10-29", "status": "CLOSED", "opening_float_xof": 100000, "opened_at": "2026-10-29T11:10:12.922192+00:00", "closed_at": "2026-10-29T16:36:46.050337+00:00", "z_number": 1, "expected_cash_xof": 214500, "counted_cash_xof": 214500, "variance_xof": 0, "totals_snapshot": {"z_number": 1, "opening_float_xof": 100000, "total_sales_ttc_xof": 114500, "total_sales_ht_xof": 114500, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 114500}, "sales_by_category": {"Poissons": 10500, "Sp\\u00e9cial Kabato": 34500, "Sp\\u00e9cial Oriental": 10500, "Sp\\u00e9cial Ivoirienne": 44000, "Sp\\u00e9cial Salade": 15000}, "sales_by_item": [{"product_name": "Sosso 7000", "category": "Poissons", "quantity": 1, "unit_price_xof": 7000, "total_ttc_xof": 7000}, {"product_name": "Kabato Dah + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3500, "total_ttc_xof": 7000}, {"product_name": "Kabato Kope + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Atti\\u00e9k\\u00e9 + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Kabato Kope + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Frites + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Petit pois + B\\u0153uf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Salade Panach\\u00e9e + Sosso 5000", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Alloco + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Couscous + Mouton", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Igname bouillie + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Alloco + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Salade Fra\\u00eeche + Sosso 4000", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Sosso 3500", "category": "Poissons", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Kabato Lafri + Mouton", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Couscous + Poisson", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Petit pois + Sosso 3500", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Igname frite + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Kabato Lafri + Boeuf", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Kabato Dah + Boeuf", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Couscous + Poulet", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Salade Panach\\u00e9e + Poulet", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Salade Fra\\u00eeche + Poulet", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Kabato Dah + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Kabato Dah + B\\u0153uf", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Atti\\u00e9k\\u00e9 + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Alloco + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 214500, "counted_cash_xof": 214500, "variance_xof": 0, "closing_breakdown": {"2000": 2, "10000": 21, "coin_500": 1}, "orders_count": 4, "cancelled_orders_count": 0}}	2026-10-29 16:36:46.094467+00	2026-10-29 16:36:46.094478+00
item-add-1793291625382-68e949d4-af85-41dc-a09f-5ef08df9fb28	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/items	58e8f08c2c1ddee1a083a69929015b83257d0688531e0798668fcd0af61bf65c	200	{"id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "order_number": "2026-10-29-0004", "cash_session_id": "43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 23000, "total_ht_xof": 23000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 23000, "items": [{"id": "1b705b20-098e-4504-8b97-1b53a198a141", "product_id": "e0648d5b-df64-444f-82cf-0d18b472b3db", "product_name_snapshot": "Sosso 3500", "category_snapshot": "Poissons", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:44.744060+00:00", "removed_at": null, "removal_reason": null}, {"id": "1b32cc23-9ad8-4a45-97c9-fb91c0d24abb", "product_id": "93418cf7-cec2-4441-925a-2917ba67479a", "product_name_snapshot": "Sosso 7000", "category_snapshot": "Poissons", "unit_price_xof": 7000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 7000, "note": null, "added_at": "2026-10-29T16:33:44.890289+00:00", "removed_at": null, "removal_reason": null}, {"id": "ddc6864b-3904-41f3-9f3a-b791af71aedc", "product_id": "fbb74d1d-e719-4478-b4fb-df4a903e41d5", "product_name_snapshot": "Kabato Kope + Poulet", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.061905+00:00", "removed_at": null, "removal_reason": null}, {"id": "34a0bc05-7144-4cf4-b542-2edb6a271273", "product_id": "78a775c5-9a24-4760-a370-483ebc35cd3d", "product_name_snapshot": "Kabato Lafri + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.194067+00:00", "removed_at": null, "removal_reason": null}, {"id": "cf4f9468-9d80-4cd0-a28f-f3ea46ac8ff2", "product_id": "3acf88aa-9368-4a0b-a967-3e79d26c59dc", "product_name_snapshot": "Kabato Dah + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-29T16:33:45.323293+00:00", "removed_at": null, "removal_reason": null}, {"id": "db889a3d-91e0-478f-ba4e-e266bcdccd46", "product_id": "e187c501-7b39-497d-95d8-832d0aa0ac66", "product_name_snapshot": "Kabato Lafri + Mouton", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-29T16:33:45.425736+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-29T16:33:44.620144+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-29 16:33:45.443289+00	2026-10-29 16:33:45.443301+00
pay-dcedcffe-336a-4484-988f-b28e1a2e7ba0-1793291635696-nx5rmin	/api/v1/orders/dcedcffe-336a-4484-988f-b28e1a2e7ba0/payments	4b4d437e81678dfdd6d9a23ceb376b2da503bd0cad7fa66ba487cce688c8734d	201	{"payment": {"id": "8716e1cf-8b3e-4a32-aeb2-19664ccb9ae7", "order_id": "dcedcffe-336a-4484-988f-b28e1a2e7ba0", "method": "CASH", "amount_xof": 33500, "tendered_xof": 33500, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-29T16:33:55.740526+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "1c37e935-f274-4360-aa93-3f074c70a32a", "fne_status": null, "warnings": []}	2026-10-29 16:33:55.842658+00	2026-10-29 16:33:55.842668+00
session-open-1793355532213-56f66366-cf79-4815-b890-c6667b538f35	/api/v1/cash-sessions	59f46f589dad21395a2319fa3edc5b8abb3ee824ffa118dee97868c25776c945	201	{"id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "cash_register_id": "caisse-01", "business_date": "2026-10-30", "status": "OPEN", "opening_float_xof": 100000, "opened_at": "2026-10-30T10:18:52.303493+00:00", "closed_at": null, "z_number": null, "expected_cash_xof": null, "counted_cash_xof": null, "variance_xof": null, "totals_snapshot": null}	2026-10-30 10:18:52.347299+00	2026-10-30 10:18:52.347307+00
item-add-1793358227822-f58a5d16-005f-4db7-a687-2d7937bb3560	/api/v1/orders/05ad026a-7ca3-47fe-a3c6-93ca6b508870/items	a426eb0cf2224e135d54b88fa923f064efa53e964bd2eac7ab031d55834394d3	200	{"id": "05ad026a-7ca3-47fe-a3c6-93ca6b508870", "order_number": "2026-10-30-0001", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "table_label": "Table 3", "note_label": "Note 1", "status": "OPEN", "guests_count": 1, "total_ttc_xof": 3000, "total_ht_xof": 3000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 3000, "items": [{"id": "ea48c73b-7797-4838-9f2f-ecc20058df81", "product_id": "f2ceb9f5-5bbe-4b7d-8f8d-87fa4e9cc0db", "product_name_snapshot": "Kabato Kope + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-30T11:03:47.859307+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:03:22.762423+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:03:47.88829+00	2026-10-30 11:03:47.888297+00
pay-05ad026a-7ca3-47fe-a3c6-93ca6b508870-1793358311927-66t1wsn	/api/v1/orders/05ad026a-7ca3-47fe-a3c6-93ca6b508870/payments	a729e654c548ba7e60c6c0b04a69b86ff704903c5dcfbf3817fc40f369365280	201	{"payment": {"id": "ece75c3c-3e70-41d0-bb85-cdf0d7ca0cbf", "order_id": "05ad026a-7ca3-47fe-a3c6-93ca6b508870", "method": "CASH", "amount_xof": 3000, "tendered_xof": 3000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-30T11:05:11.993773+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "da4445ef-905a-4d96-b5cf-65a73bb5ee99", "fne_status": null, "warnings": []}	2026-10-30 11:05:12.103056+00	2026-10-30 11:05:12.103071+00
item-add-1793358611908-97d154b9-79c4-40ac-91b8-d504bb887276	/api/v1/orders/1b4709eb-7431-4782-8ff3-bd821ed4b2ec/items	a426eb0cf2224e135d54b88fa923f064efa53e964bd2eac7ab031d55834394d3	200	{"id": "1b4709eb-7431-4782-8ff3-bd821ed4b2ec", "order_number": "2026-10-30-0002", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "table_label": "Table 2", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 3000, "total_ht_xof": 3000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 3000, "items": [{"id": "079270e7-fdd9-47c8-ae6e-580f83a4d0ed", "product_id": "f2ceb9f5-5bbe-4b7d-8f8d-87fa4e9cc0db", "product_name_snapshot": "Kabato Kope + Boeuf", "category_snapshot": "Sp\\u00e9cial Kabato", "unit_price_xof": 3000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3000, "note": null, "added_at": "2026-10-30T11:10:11.948983+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:10:11.857170+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:10:11.966868+00	2026-10-30 11:10:11.966877+00
pay-1b4709eb-7431-4782-8ff3-bd821ed4b2ec-1793358616553-m6iajo8	/api/v1/orders/1b4709eb-7431-4782-8ff3-bd821ed4b2ec/payments	a729e654c548ba7e60c6c0b04a69b86ff704903c5dcfbf3817fc40f369365280	201	{"payment": {"id": "a00ab204-76cc-41e3-a653-4bca4eb1fa69", "order_id": "1b4709eb-7431-4782-8ff3-bd821ed4b2ec", "method": "CASH", "amount_xof": 3000, "tendered_xof": 3000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-30T11:10:16.594968+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "0c75c0f8-c504-4623-accf-fea75dba276e", "fne_status": null, "warnings": []}	2026-10-30 11:10:16.671763+00	2026-10-30 11:10:16.671778+00
item-add-1793358720927-7065415d-97d8-4d00-9afe-5c352ac31d5c	/api/v1/orders/c9bc61b4-ad71-4a9f-93c6-918d772fb438/items	624b617ef2142b3465318b224acc1e4b3fc6db0006c002f78f3568d0cf153aba	200	{"id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "order_number": "2026-10-30-0003", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 3500, "total_ht_xof": 3500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 3500, "items": [{"id": "ae8c1b03-97ca-4fca-b599-b62195f3cd51", "product_id": "d354b5f0-e3a9-4024-9a11-6524de50706c", "product_name_snapshot": "Foutou + Pistache poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:00.964641+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:12:00.869434+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:12:00.979915+00	2026-10-30 11:12:00.979923+00
item-add-1793358721022-9ee07097-79dd-49f3-875f-a81a8c3d4354	/api/v1/orders/c9bc61b4-ad71-4a9f-93c6-918d772fb438/items	6c7b93e09b2e86c7147558c0b4e1fa6de4b162daade1115f0843e003ca1a4783	200	{"id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "order_number": "2026-10-30-0003", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 7500, "total_ht_xof": 7500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 7500, "items": [{"id": "ae8c1b03-97ca-4fca-b599-b62195f3cd51", "product_id": "d354b5f0-e3a9-4024-9a11-6524de50706c", "product_name_snapshot": "Foutou + Pistache poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:00.964641+00:00", "removed_at": null, "removal_reason": null}, {"id": "70224647-ff1a-405c-844c-62c1b1d3130b", "product_id": "8b637a4c-48a2-4b14-b5c5-e233a972a424", "product_name_snapshot": "Foutou gouagouassou + Mouton", "category_snapshot": "Foufou / foutou", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-30T11:12:01.063729+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:12:00.869434+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:12:01.081934+00	2026-10-30 11:12:01.081952+00
item-add-1793358721482-81269b21-b587-4b9b-972d-c5889e532470	/api/v1/orders/c9bc61b4-ad71-4a9f-93c6-918d772fb438/items	71bc529ccb54028927ad2561b97b9ed0d1fbf7b8bc44051be8e15d278b01bcb7	200	{"id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "order_number": "2026-10-30-0003", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 25500, "total_ht_xof": 25500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 25500, "items": [{"id": "ae8c1b03-97ca-4fca-b599-b62195f3cd51", "product_id": "d354b5f0-e3a9-4024-9a11-6524de50706c", "product_name_snapshot": "Foutou + Pistache poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:00.964641+00:00", "removed_at": null, "removal_reason": null}, {"id": "70224647-ff1a-405c-844c-62c1b1d3130b", "product_id": "8b637a4c-48a2-4b14-b5c5-e233a972a424", "product_name_snapshot": "Foutou gouagouassou + Mouton", "category_snapshot": "Foufou / foutou", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-30T11:12:01.063729+00:00", "removed_at": null, "removal_reason": null}, {"id": "a585b556-87e4-4302-8160-a2a342eb99d4", "product_id": "ab541db9-d472-4db5-b3aa-ffc75fb46468", "product_name_snapshot": "Foutou gouagouassou + Poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.172335+00:00", "removed_at": null, "removal_reason": null}, {"id": "6099bd33-f0d3-42ed-ad6b-c13d3f74e1fe", "product_id": "0ae6808c-7e1e-49f0-856a-ebfe2232965b", "product_name_snapshot": "Foutou gouagouassou + Poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.269168+00:00", "removed_at": null, "removal_reason": null}, {"id": "de335dd4-55c1-44a5-9a9e-569dcec3f62f", "product_id": "3711b33e-f1bf-4416-91ea-5a85e467fe7b", "product_name_snapshot": "Foutou graine + B\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.352087+00:00", "removed_at": null, "removal_reason": null}, {"id": "d62d4f89-0e16-482e-ae46-95334f9006c5", "product_id": "17f0a5d7-b947-44af-8d36-5d17846b8fe8", "product_name_snapshot": "Foutou graine + Mouton", "category_snapshot": "Foufou / foutou", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-30T11:12:01.428556+00:00", "removed_at": null, "removal_reason": null}, {"id": "30da91b1-bd3a-4ffe-9a86-f0ffb4e157b8", "product_id": "176b9a0f-e557-43fa-8d36-5b111810a5e2", "product_name_snapshot": "Foutou graine + Poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.509720+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:12:00.869434+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:12:01.523768+00	2026-10-30 11:12:01.523779+00
item-add-1793358721139-86e5e2f5-a048-4aa2-973b-eab20a77e517	/api/v1/orders/c9bc61b4-ad71-4a9f-93c6-918d772fb438/items	2089fe7345007d9cfb4dcd47e8e7e8e40e4b7cf4a506f98b9835eb84a60712da	200	{"id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "order_number": "2026-10-30-0003", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 11000, "total_ht_xof": 11000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 11000, "items": [{"id": "ae8c1b03-97ca-4fca-b599-b62195f3cd51", "product_id": "d354b5f0-e3a9-4024-9a11-6524de50706c", "product_name_snapshot": "Foutou + Pistache poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:00.964641+00:00", "removed_at": null, "removal_reason": null}, {"id": "70224647-ff1a-405c-844c-62c1b1d3130b", "product_id": "8b637a4c-48a2-4b14-b5c5-e233a972a424", "product_name_snapshot": "Foutou gouagouassou + Mouton", "category_snapshot": "Foufou / foutou", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-30T11:12:01.063729+00:00", "removed_at": null, "removal_reason": null}, {"id": "a585b556-87e4-4302-8160-a2a342eb99d4", "product_id": "ab541db9-d472-4db5-b3aa-ffc75fb46468", "product_name_snapshot": "Foutou gouagouassou + Poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.172335+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:12:00.869434+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:12:01.186141+00	2026-10-30 11:12:01.186152+00
item-add-1793358721224-188b0a84-6d88-4c48-9117-e60648176f69	/api/v1/orders/c9bc61b4-ad71-4a9f-93c6-918d772fb438/items	cc7b263a4da057b81691e796f670929984b1790dc7ab84ccfad7bba20776760b	200	{"id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "order_number": "2026-10-30-0003", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 14500, "total_ht_xof": 14500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 14500, "items": [{"id": "ae8c1b03-97ca-4fca-b599-b62195f3cd51", "product_id": "d354b5f0-e3a9-4024-9a11-6524de50706c", "product_name_snapshot": "Foutou + Pistache poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:00.964641+00:00", "removed_at": null, "removal_reason": null}, {"id": "70224647-ff1a-405c-844c-62c1b1d3130b", "product_id": "8b637a4c-48a2-4b14-b5c5-e233a972a424", "product_name_snapshot": "Foutou gouagouassou + Mouton", "category_snapshot": "Foufou / foutou", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-30T11:12:01.063729+00:00", "removed_at": null, "removal_reason": null}, {"id": "a585b556-87e4-4302-8160-a2a342eb99d4", "product_id": "ab541db9-d472-4db5-b3aa-ffc75fb46468", "product_name_snapshot": "Foutou gouagouassou + Poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.172335+00:00", "removed_at": null, "removal_reason": null}, {"id": "6099bd33-f0d3-42ed-ad6b-c13d3f74e1fe", "product_id": "0ae6808c-7e1e-49f0-856a-ebfe2232965b", "product_name_snapshot": "Foutou gouagouassou + Poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.269168+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:12:00.869434+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:12:01.281903+00	2026-10-30 11:12:01.28191+00
item-add-1793358721323-df4adb66-6015-4102-9222-d824c4b0c238	/api/v1/orders/c9bc61b4-ad71-4a9f-93c6-918d772fb438/items	7f03f16fe1046b96e3d013ed6b454c893f1093353a087bbcdbf5bfc1a6962a02	200	{"id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "order_number": "2026-10-30-0003", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 18000, "total_ht_xof": 18000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 18000, "items": [{"id": "ae8c1b03-97ca-4fca-b599-b62195f3cd51", "product_id": "d354b5f0-e3a9-4024-9a11-6524de50706c", "product_name_snapshot": "Foutou + Pistache poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:00.964641+00:00", "removed_at": null, "removal_reason": null}, {"id": "70224647-ff1a-405c-844c-62c1b1d3130b", "product_id": "8b637a4c-48a2-4b14-b5c5-e233a972a424", "product_name_snapshot": "Foutou gouagouassou + Mouton", "category_snapshot": "Foufou / foutou", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-30T11:12:01.063729+00:00", "removed_at": null, "removal_reason": null}, {"id": "a585b556-87e4-4302-8160-a2a342eb99d4", "product_id": "ab541db9-d472-4db5-b3aa-ffc75fb46468", "product_name_snapshot": "Foutou gouagouassou + Poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.172335+00:00", "removed_at": null, "removal_reason": null}, {"id": "6099bd33-f0d3-42ed-ad6b-c13d3f74e1fe", "product_id": "0ae6808c-7e1e-49f0-856a-ebfe2232965b", "product_name_snapshot": "Foutou gouagouassou + Poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.269168+00:00", "removed_at": null, "removal_reason": null}, {"id": "de335dd4-55c1-44a5-9a9e-569dcec3f62f", "product_id": "3711b33e-f1bf-4416-91ea-5a85e467fe7b", "product_name_snapshot": "Foutou graine + B\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.352087+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:12:00.869434+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:12:01.36506+00	2026-10-30 11:12:01.365069+00
item-add-1793358721402-6b01f3ab-f7f8-47d8-8b4d-27588c1fd1f6	/api/v1/orders/c9bc61b4-ad71-4a9f-93c6-918d772fb438/items	3822f8047a054e6a0197a03ac8c9fbecdabb789bb7a02c4b1e07f1ff875785be	200	{"id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "order_number": "2026-10-30-0003", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "table_label": "Table 4", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 22000, "total_ht_xof": 22000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 22000, "items": [{"id": "ae8c1b03-97ca-4fca-b599-b62195f3cd51", "product_id": "d354b5f0-e3a9-4024-9a11-6524de50706c", "product_name_snapshot": "Foutou + Pistache poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:00.964641+00:00", "removed_at": null, "removal_reason": null}, {"id": "70224647-ff1a-405c-844c-62c1b1d3130b", "product_id": "8b637a4c-48a2-4b14-b5c5-e233a972a424", "product_name_snapshot": "Foutou gouagouassou + Mouton", "category_snapshot": "Foufou / foutou", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-30T11:12:01.063729+00:00", "removed_at": null, "removal_reason": null}, {"id": "a585b556-87e4-4302-8160-a2a342eb99d4", "product_id": "ab541db9-d472-4db5-b3aa-ffc75fb46468", "product_name_snapshot": "Foutou gouagouassou + Poisson", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.172335+00:00", "removed_at": null, "removal_reason": null}, {"id": "6099bd33-f0d3-42ed-ad6b-c13d3f74e1fe", "product_id": "0ae6808c-7e1e-49f0-856a-ebfe2232965b", "product_name_snapshot": "Foutou gouagouassou + Poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.269168+00:00", "removed_at": null, "removal_reason": null}, {"id": "de335dd4-55c1-44a5-9a9e-569dcec3f62f", "product_id": "3711b33e-f1bf-4416-91ea-5a85e467fe7b", "product_name_snapshot": "Foutou graine + B\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:12:01.352087+00:00", "removed_at": null, "removal_reason": null}, {"id": "d62d4f89-0e16-482e-ae46-95334f9006c5", "product_id": "17f0a5d7-b947-44af-8d36-5d17846b8fe8", "product_name_snapshot": "Foutou graine + Mouton", "category_snapshot": "Foufou / foutou", "unit_price_xof": 4000, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 4000, "note": null, "added_at": "2026-10-30T11:12:01.428556+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:12:00.869434+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:12:01.44331+00	2026-10-30 11:12:01.44332+00
pay-c9bc61b4-ad71-4a9f-93c6-918d772fb438-1793358736017-0adwpxo	/api/v1/orders/c9bc61b4-ad71-4a9f-93c6-918d772fb438/payments	e6cf8483df665e978ca4f15eb65330423e7b3f69698b748201ba6a9ed22eb449	201	{"payment": {"id": "b435a1c1-0b7b-44df-8887-03062f0e071c", "order_id": "c9bc61b4-ad71-4a9f-93c6-918d772fb438", "method": "CASH", "amount_xof": 25500, "tendered_xof": 30000, "change_xof": 4500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-30T11:12:16.062962+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 4500, "drawer_opened": true, "print_job_id": "65334c18-4710-4307-8b7d-0aef817c7d33", "fne_status": null, "warnings": []}	2026-10-30 11:12:16.179505+00	2026-10-30 11:12:16.179529+00
item-add-1793359956901-c64e03a8-b8ce-4dfe-8e65-c79a7ffa46b0	/api/v1/orders/ff8f5b34-95af-4d39-90dd-2308a7d41876/items	440d7622f070ee953f4e556bd43b19db1643179e70a2b45ea1291f80e5199df6	200	{"id": "ff8f5b34-95af-4d39-90dd-2308a7d41876", "order_number": "2026-10-30-0004", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "table_label": "Table 1", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 3500, "total_ht_xof": 3500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 3500, "items": [{"id": "8cc4a9e5-1b4f-4342-a8a2-1d1bb8419de8", "product_id": "ceafb668-7cd6-4c8f-90cd-f44a62dc5c26", "product_name_snapshot": "Foufou/foutou b\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:36.947243+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:32:36.848704+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:32:36.968532+00	2026-10-30 11:32:36.968541+00
item-add-1793359957010-84cf1432-c155-46cc-87a6-3ade21622139	/api/v1/orders/ff8f5b34-95af-4d39-90dd-2308a7d41876/items	fd828670c1c4f5277963a780001dcfa2659b0f1f405c44063d68e8a222ec22ac	200	{"id": "ff8f5b34-95af-4d39-90dd-2308a7d41876", "order_number": "2026-10-30-0004", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "table_label": "Table 1", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 7000, "total_ht_xof": 7000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 7000, "items": [{"id": "8cc4a9e5-1b4f-4342-a8a2-1d1bb8419de8", "product_id": "ceafb668-7cd6-4c8f-90cd-f44a62dc5c26", "product_name_snapshot": "Foufou/foutou b\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:36.947243+00:00", "removed_at": null, "removal_reason": null}, {"id": "0289f245-63b2-4ce2-8774-924e3a3d5727", "product_id": "bfee22fc-f027-48c3-92af-f2f2f6e6145b", "product_name_snapshot": "Foufou/foutou poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:37.052083+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:32:36.848704+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:32:37.068241+00	2026-10-30 11:32:37.068251+00
item-add-1793359957126-61e9c3db-9ff0-46f2-a7fa-664a95b0ad25	/api/v1/orders/ff8f5b34-95af-4d39-90dd-2308a7d41876/items	6a57c2e0946c21ac0425146f7518ddea5febcf3512b7d8b81d2d3c9e5ea865eb	200	{"id": "ff8f5b34-95af-4d39-90dd-2308a7d41876", "order_number": "2026-10-30-0004", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "table_label": "Table 1", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 10500, "total_ht_xof": 10500, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 10500, "items": [{"id": "8cc4a9e5-1b4f-4342-a8a2-1d1bb8419de8", "product_id": "ceafb668-7cd6-4c8f-90cd-f44a62dc5c26", "product_name_snapshot": "Foufou/foutou b\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:36.947243+00:00", "removed_at": null, "removal_reason": null}, {"id": "0289f245-63b2-4ce2-8774-924e3a3d5727", "product_id": "bfee22fc-f027-48c3-92af-f2f2f6e6145b", "product_name_snapshot": "Foufou/foutou poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:37.052083+00:00", "removed_at": null, "removal_reason": null}, {"id": "81f15313-d890-43b7-8a5f-2d6abacf0299", "product_id": "c0fd4f28-d8a7-45db-9637-1ad10947cba0", "product_name_snapshot": "Foufou sauce claire + B\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:37.175306+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:32:36.848704+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:32:37.188261+00	2026-10-30 11:32:37.188269+00
item-add-1793359957221-a0f970ac-0ba6-43e5-92f0-cac2db383198	/api/v1/orders/ff8f5b34-95af-4d39-90dd-2308a7d41876/items	4493c025feba404ba2f7a9d3e8db97c2de8de8cd83712f21447456e2140d0fdc	200	{"id": "ff8f5b34-95af-4d39-90dd-2308a7d41876", "order_number": "2026-10-30-0004", "cash_session_id": "e392e6cf-0283-47b9-b17f-c0400f0f0a6f", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "table_label": "Table 1", "note_label": "Note 1", "status": "OPEN", "guests_count": 4, "total_ttc_xof": 14000, "total_ht_xof": 14000, "total_vat_xof": 0, "paid_xof": 0, "due_xof": 14000, "items": [{"id": "8cc4a9e5-1b4f-4342-a8a2-1d1bb8419de8", "product_id": "ceafb668-7cd6-4c8f-90cd-f44a62dc5c26", "product_name_snapshot": "Foufou/foutou b\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:36.947243+00:00", "removed_at": null, "removal_reason": null}, {"id": "0289f245-63b2-4ce2-8774-924e3a3d5727", "product_id": "bfee22fc-f027-48c3-92af-f2f2f6e6145b", "product_name_snapshot": "Foufou/foutou poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:37.052083+00:00", "removed_at": null, "removal_reason": null}, {"id": "81f15313-d890-43b7-8a5f-2d6abacf0299", "product_id": "c0fd4f28-d8a7-45db-9637-1ad10947cba0", "product_name_snapshot": "Foufou sauce claire + B\\u0153uf", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:37.175306+00:00", "removed_at": null, "removal_reason": null}, {"id": "080cefe1-d22d-4e91-984b-b20f3dcc7992", "product_id": "578fbb1b-8dea-4372-919e-464656bcc8e4", "product_name_snapshot": "Foufou sauce claire + Poulet", "category_snapshot": "Foufou / foutou", "unit_price_xof": 3500, "quantity": 1, "vat_rate": 0.0, "line_total_xof": 3500, "note": null, "added_at": "2026-10-30T11:32:37.257277+00:00", "removed_at": null, "removal_reason": null}], "opened_at": "2026-10-30T11:32:36.848704+00:00", "paid_at": null, "cancelled_reason": null}	2026-10-30 11:32:37.270496+00	2026-10-30 11:32:37.270505+00
pay-ff8f5b34-95af-4d39-90dd-2308a7d41876-1793359966275-t79p6i2	/api/v1/orders/ff8f5b34-95af-4d39-90dd-2308a7d41876/payments	79fa79b936cd8f14454b8117bcff40bd9fca9c7d01400c9b3eb8d6d7d9507eae	201	{"payment": {"id": "684a5a0a-b655-4e10-89ae-6c1654c74a77", "order_id": "ff8f5b34-95af-4d39-90dd-2308a7d41876", "method": "CASH", "amount_xof": 14000, "tendered_xof": 14000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-30T11:32:46.307774+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "c2994709-d2ff-4293-8044-ed7c3b95990a", "fne_status": null, "warnings": []}	2026-10-30 11:32:46.36908+00	2026-10-30 11:32:46.36909+00
\.


--
-- Data for Name: justificatifs; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.justificatifs (id, operation_decaissement_id, nom_fichier, chemin_fichier, type_document, uploaded_by, uploaded_at) FROM stdin;
126	607	logo-dark.png	uploads/95750bf74e8441b584c8b797bcc6b4fc_logo-dark.png	facture	433	2026-09-28 11:42:02.82665+00
133	653	WhatsApp Image 2026-10-06 at 11.54.58.jpeg	uploads/9b998310668447d387cdeaa4ff224b2d_WhatsApp Image 2026-10-06 at 11.54.58.jpeg	facture	433	2026-10-07 10:24:59.905425+00
134	654	WhatsApp Image 2026-10-06 at 11.54.58.jpeg	uploads/7cf24c022ff8496f81df2016e2922cd4_WhatsApp Image 2026-10-06 at 11.54.58.jpeg	facture	433	2026-10-07 10:58:43.756946+00
22	85	Gemini_Generated_Image_xxrg89xxrg89xxrg.jpeg	uploads/864d45f6002a4e8bb1c47a21f7eba11b_Gemini_Generated_Image_xxrg89xxrg89xxrg.jpeg	facture	433	2026-09-03 07:51:29.357921+00
23	86	RQC_Journee_270-1.pdf	uploads/45298ffa042a49e8953c95cd3214b7ed_RQC_Journee_270-1.pdf	facture	433	2026-09-03 09:18:42.801001+00
24	87	RQC_Journee_270-1.pdf	uploads/d1aa38efd1cf418cb6dba7239569dabf_RQC_Journee_270-1.pdf	facture	433	2026-09-03 10:05:15.139398+00
87	374	Bilan_Mensuel_2026-09-1.pdf	uploads/a32df5fa88f34cb99fbda8ef8e155754_Bilan_Mensuel_2026-09-1.pdf	facture	433	2026-09-07 10:47:11.029031+00
88	380	logo-dark.png	uploads/95384baa1f8540e4b822e9fc5536edb9_logo-dark.png	facture	433	2026-09-07 11:24:33.563356+00
89	384	Journal_Tresorerie_2026-09-07.pdf	uploads/0b952c42f3be43aba822f9a2e4e0a1cc_Journal_Tresorerie_2026-09-07.pdf	facture	433	2026-09-07 11:50:56.138533+00
37	128	WhatsApp Image 2026-09-02 at 09.26.01.jpeg	uploads/8fe5c92cb9dc46929b8fdd15aa85ddbb_WhatsApp Image 2026-09-02 at 09.26.01.jpeg	facture	433	2026-09-04 09:53:10.633117+00
92	400	Bilan_Mensuel_2026-09-3.pdf	uploads/e709e80b956c4828ad98144fa658ae73_Bilan_Mensuel_2026-09-3.pdf	facture	433	2026-09-08 14:13:26.597106+00
93	403	logo-dark.png	uploads/2f0e4346fae34563ac9f481809962466_logo-dark.png	facture	433	2026-09-08 14:23:05.055701+00
94	404	logo-dark.png	uploads/2575f9bd0a524e188163fc9e394c758c_logo-dark.png	facture	433	2026-09-08 14:23:56.11825+00
95	405	logo-dark.png	uploads/54fb5b94b8de496881a776d2334c75d7_logo-dark.png	facture	433	2026-09-08 14:25:19.140217+00
96	406	logo-dark.png	uploads/7db3e1c5edb9427aa8178db73e9bc159_logo-dark.png	facture	433	2026-09-08 14:46:33.393191+00
97	414	logo-dark.png	uploads/08c6e7899a2c472aad4af6fa7acdd039_logo-dark.png	facture	433	2026-09-08 14:54:47.131901+00
44	147	Gestion de Caisse.pdf	uploads/4e1cbf4bf0ea43aabe9934d765d3f496_Gestion de Caisse.pdf	facture	433	2026-09-04 15:25:59.186679+00
45	148	screencapture-localhost-5173-dashboard-2026-08-20-12_42_26.png	uploads/af1ec3c50a58436893b8f084da866134_screencapture-localhost-5173-dashboard-2026-08-20-12_42_26.png	facture	433	2026-09-04 15:28:32.659392+00
98	416	logo-dark.png	uploads/abbc446a964f49fcaddbdbfaed44581b_logo-dark.png	facture	433	2026-09-08 15:00:08.275868+00
99	418	logo-dark.png	uploads/551acd80475f422a8448c1b0cf33910a_logo-dark.png	facture	433	2026-09-08 15:08:24.281395+00
50	162	WhatsApp Image 2026-09-02 at 09.26.01.jpeg	uploads/0972b4bdd91845b6b3ae3f309d13e1bd_WhatsApp Image 2026-09-02 at 09.26.01.jpeg	facture	433	2026-09-05 17:59:56.159924+00
104	455	logo-dark.png	uploads/a5f73b0d9183420881ff3c61e74fca94_logo-dark.png	facture	433	2026-09-10 14:39:59.705575+00
105	456	logo-dark.png	uploads/67ce3c3636d44f1ab738ac23478676ed_logo-dark.png	facture	433	2026-09-10 14:44:28.967799+00
106	457	logo-dark.png	uploads/be35cad53d5f4df896a6e2b51ab27628_logo-dark.png	facture	433	2026-09-10 14:46:06.802207+00
\.


--
-- Data for Name: market_purchase_items; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.market_purchase_items (id, purchase_list_id, article_id, quantity, unit_price_xof, total_price_xof, created_at, updated_at) FROM stdin;
f24be3c6-7a81-459c-98ca-d2b289c9b018	e8ea685b-899f-4ec9-a631-e31c45ebb951	ebb5f404-2267-4fa1-bd71-dd9e54707294	10.000	4000	40000	2026-10-29 12:25:29.881943+00	2026-10-29 12:25:29.881954+00
968654e5-b427-4ea6-9a06-11f185ff4789	e8ea685b-899f-4ec9-a631-e31c45ebb951	0e520485-53a3-403a-8dc8-547417bb83e4	10.000	960	9600	2026-10-29 12:25:29.881964+00	2026-10-29 12:25:29.881966+00
6f094782-f1b0-4b4a-91d4-b687d06b340a	e8ea685b-899f-4ec9-a631-e31c45ebb951	258570a6-aee0-4adb-a7e1-526f56b06506	10.000	800	8000	2026-10-29 12:25:29.881973+00	2026-10-29 12:25:29.881976+00
8c65f8d9-d8a3-49de-ae18-7e0446efa6bb	e8ea685b-899f-4ec9-a631-e31c45ebb951	5e5c8e90-160b-4766-abc5-0b06087c6456	10.000	500	5000	2026-10-29 12:25:29.881983+00	2026-10-29 12:25:29.881986+00
1ccc86ae-c2a6-4c59-ae5f-21ddbb75a4fd	e8ea685b-899f-4ec9-a631-e31c45ebb951	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	10.000	556	5560	2026-10-29 12:25:29.881993+00	2026-10-29 12:25:29.881995+00
0f364abb-671c-40c7-be3f-2d2d37054148	e8ea685b-899f-4ec9-a631-e31c45ebb951	e4af9701-0d10-404a-9371-a0e7c84ec8f1	10.000	5500	55000	2026-10-29 12:25:29.882003+00	2026-10-29 12:25:29.882005+00
250e714f-5044-477f-bf7f-a9bcd48abdbf	e8ea685b-899f-4ec9-a631-e31c45ebb951	8353e03f-35a0-44f9-ad7a-5c4336f90725	10.000	3000	30000	2026-10-29 12:25:29.882011+00	2026-10-29 12:25:29.882014+00
a534bc06-52c3-4b34-a12f-7025d3ea0012	e8ea685b-899f-4ec9-a631-e31c45ebb951	07ee94bb-1c62-4d20-b9e3-9b2aa9132f4a	10.000	4000	40000	2026-10-29 12:25:29.882019+00	2026-10-29 12:25:29.882022+00
bbfa76de-a327-452d-a73d-2e1c37960ba6	e8ea685b-899f-4ec9-a631-e31c45ebb951	a4cbfa56-e146-4cec-b536-34c376c34e28	10.000	1540	15400	2026-10-29 12:25:29.882029+00	2026-10-29 12:25:29.882032+00
d1a80243-9b49-436b-b58c-6f3def2c4a17	e8ea685b-899f-4ec9-a631-e31c45ebb951	0d45efe2-2e7f-4d3c-a266-7bb742479fac	1.000	750	750	2026-10-29 12:25:29.882037+00	2026-10-29 12:25:29.88204+00
e34e455e-f9c4-4add-9ea6-faded59e9be3	e8ea685b-899f-4ec9-a631-e31c45ebb951	d4d263e4-aefa-4d09-bbbc-ba1edc1fb6d9	1.000	750	750	2026-10-29 12:25:29.882046+00	2026-10-29 12:25:29.882048+00
e5f09856-61d9-47c2-a1ea-faf0eee907e8	e8ea685b-899f-4ec9-a631-e31c45ebb951	7c1d3f7d-dcab-46e0-89b7-a2e0154f4d37	1.000	1000	1000	2026-10-29 12:25:29.882055+00	2026-10-29 12:25:29.882057+00
e8efb3de-9eef-40f5-8680-95a800cbe87b	e8ea685b-899f-4ec9-a631-e31c45ebb951	888b71eb-baa9-42c4-baa1-fc5ee188b1b1	1.000	3000	3000	2026-10-29 12:25:29.882064+00	2026-10-29 12:25:29.882067+00
e7097482-ab0a-4128-94e0-9aae1967323c	e8ea685b-899f-4ec9-a631-e31c45ebb951	d1a4136a-5831-4b23-8438-d6f5f15f84fc	1.000	84	84	2026-10-29 12:25:29.882074+00	2026-10-29 12:25:29.882077+00
699d7785-60ac-42e6-b991-9b70f4ccadb1	e8ea685b-899f-4ec9-a631-e31c45ebb951	8ea90fe3-d7e3-4186-a5db-d459dc24d98d	1.000	2250	2250	2026-10-29 12:25:29.882083+00	2026-10-29 12:25:29.882085+00
c3e0b1f6-af8c-49ae-80f9-80b5379c8862	e8ea685b-899f-4ec9-a631-e31c45ebb951	6f0d0280-57dc-4d8f-93b4-a2f20c3bdcf1	1.000	1000	1000	2026-10-29 12:25:29.882091+00	2026-10-29 12:25:29.882094+00
3a199bbb-0e54-4f4e-a8cb-c154099736eb	e8ea685b-899f-4ec9-a631-e31c45ebb951	ab69a04c-8b53-4b94-8620-ad36447574a2	1.000	5000	5000	2026-10-29 12:25:29.8821+00	2026-10-29 12:25:29.882103+00
ab86ca9c-59a3-4db8-9bb0-bde55936727f	e8ea685b-899f-4ec9-a631-e31c45ebb951	c23a7da5-5358-4a87-bb97-981a779f3e34	2.000	500	1000	2026-10-29 12:25:29.882109+00	2026-10-29 12:25:29.882111+00
a5e0c8b1-5d0d-45af-8fbb-c520f5271b65	e8ea685b-899f-4ec9-a631-e31c45ebb951	aeacf1df-c17b-4055-9fd5-204dac99c2fd	2.000	3500	7000	2026-10-29 12:25:29.882117+00	2026-10-29 12:25:29.88212+00
1ee47302-37e2-48cf-8d5b-a311b75a4ad9	e8ea685b-899f-4ec9-a631-e31c45ebb951	5deeb776-8c5f-48ec-9ef7-c55f2d51d15d	2.000	1000	2000	2026-10-29 12:25:29.882126+00	2026-10-29 12:25:29.882129+00
f8c3a169-b8e1-4591-a5aa-1abba6149c5e	e8ea685b-899f-4ec9-a631-e31c45ebb951	98fa99bd-50a1-4767-a147-f0a77cdbf912	2.000	3500	7000	2026-10-29 12:25:29.882135+00	2026-10-29 12:25:29.882137+00
25e49de1-55ef-4cd5-b5f0-0fa63d8d7312	e8ea685b-899f-4ec9-a631-e31c45ebb951	cb9130fc-ac18-4530-acf5-2db2641753f3	2.000	10000	20000	2026-10-29 12:25:29.882144+00	2026-10-29 12:25:29.882146+00
0012156b-ef15-4a05-95f9-45993f3af82b	e8ea685b-899f-4ec9-a631-e31c45ebb951	26290d66-6767-41d8-ba7e-40916c397c90	2.000	10000	20000	2026-10-29 12:25:29.882153+00	2026-10-29 12:25:29.882155+00
19a6a6e7-8097-4791-9f60-54696d9f9258	e8ea685b-899f-4ec9-a631-e31c45ebb951	de94d296-4c58-42ff-920b-691baab6902d	2.000	3000	6000	2026-10-29 12:25:29.882162+00	2026-10-29 12:25:29.882164+00
57a9f5d4-eef2-480e-ad84-52971300ba2c	e8ea685b-899f-4ec9-a631-e31c45ebb951	02a19865-af2d-466d-9754-363c10dcda24	1.000	1000	1000	2026-10-29 12:25:29.882171+00	2026-10-29 12:25:29.882173+00
d139c86a-b5ee-4aef-b601-344a3f956ba1	e8ea685b-899f-4ec9-a631-e31c45ebb951	2b2efe1b-6b47-4228-9508-82c43be96592	1.000	1000	1000	2026-10-29 12:25:29.882179+00	2026-10-29 12:25:29.882182+00
74fb3553-81b1-4d13-b814-f8ec931d1782	e8ea685b-899f-4ec9-a631-e31c45ebb951	2e397e12-f4b0-4c25-96af-63ea19feb790	2.000	500	1000	2026-10-29 12:25:29.882188+00	2026-10-29 12:25:29.88219+00
dc6a8bcc-d199-455e-b531-71746c03db04	e8ea685b-899f-4ec9-a631-e31c45ebb951	1cae06ac-04d4-4d22-a52d-487e50268463	1.000	2000	2000	2026-10-29 12:25:29.882196+00	2026-10-29 12:25:29.882199+00
6b5f31ef-428f-44ae-938e-c067b127b62c	e8ea685b-899f-4ec9-a631-e31c45ebb951	c5ce6682-51d4-443f-bb2f-fda4a32b0cb1	2.000	500	1000	2026-10-29 12:25:29.882205+00	2026-10-29 12:25:29.882207+00
a1ebce03-4066-41a2-9b97-9730f2561236	e8ea685b-899f-4ec9-a631-e31c45ebb951	e7c0a607-ae01-4648-86cd-74b12a91e834	1.000	500	500	2026-10-29 12:25:29.882214+00	2026-10-29 12:25:29.882216+00
1e999bc8-14b5-422d-b4fa-e099ab66c7e8	e8ea685b-899f-4ec9-a631-e31c45ebb951	7eb839f2-bc73-4b36-b971-9ed13a5bddd3	2.000	700	1400	2026-10-29 12:25:29.882222+00	2026-10-29 12:25:29.882225+00
8dce2263-7962-4651-b5bd-a1672453be5f	e8ea685b-899f-4ec9-a631-e31c45ebb951	c656b6a5-29d0-4e05-a85a-beb25e986bc4	2.000	400	800	2026-10-29 12:25:29.882231+00	2026-10-29 12:25:29.882233+00
e7790515-50f6-4878-9d0e-1de898fe06be	e8ea685b-899f-4ec9-a631-e31c45ebb951	c2e33d74-f331-415d-bfeb-7c42f66e0296	2.000	1400	2800	2026-10-29 12:25:29.882239+00	2026-10-29 12:25:29.882242+00
b552c48a-f22c-4344-bd31-555190aeca0a	e8ea685b-899f-4ec9-a631-e31c45ebb951	08cb25bf-cdde-4549-9392-f4bf2a9d2909	2.000	1500	3000	2026-10-29 12:25:29.882248+00	2026-10-29 12:25:29.882251+00
887cd3bb-9cac-4ccb-ba37-0a257084945a	e8ea685b-899f-4ec9-a631-e31c45ebb951	f1b1bd4d-2444-4dc3-a02b-d2e38bd81551	1.000	106	106	2026-10-29 12:25:29.882256+00	2026-10-29 12:25:29.882259+00
\.


--
-- Data for Name: market_purchase_lists; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.market_purchase_lists (id, business_date, status, created_by_user_id, validated_by_user_id, total_budget_xof, notes, created_at, updated_at) FROM stdin;
e8ea685b-899f-4ec9-a631-e31c45ebb951	2026-10-29	COMPLETED	a3e01053-c2ad-4631-910a-0eb48345e5b1	4b5224bf-057a-4654-b13e-0e65ff403161	300000	\N	2026-10-29 12:25:29.656147+00	2026-10-29 15:46:47.829437+00
\.


--
-- Data for Name: operations_decaissement; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.operations_decaissement (id, caisse_journee_id, date_operation, objet, designation, categorie_id, fournisseur_id, executant_id, n_facture, n_piece_caisse, montant, autorisation_id, created_at) FROM stdin;
128	370	2026-09-04	ACPTE ACHAT DE YAOURT	ACPTE ACHAT DE YAOURT	7	4	433	23125	36524	59000.00	\N	2026-09-04 09:53:10.40589+00
129	370	2026-09-04	SOLDE FACTURE	SABIMEX	15	\N	433	\N	\N	39600.00	\N	2026-09-04 14:42:20.340888+00
454	1261	2026-09-10	VERSEMENT ECOBANK	Versement	13	\N	433	\N	ver12435	65000.00	\N	2026-09-10 14:38:47.481289+00
374	1080	2026-09-07	ACHAT EAU AWA	Achat eau awa à Solibra	7	4	433	3215468	69857	89000.00	\N	2026-09-07 10:47:10.864446+00
375	1080	2026-09-07	TRANSPORT DOSSO	Transport Achat Mat	8	\N	433	\N	231564	20000.00	\N	2026-09-07 10:54:48.067841+00
455	1261	2026-09-10	ACPTE ACHAT PETIT POIDS TALPE	ACPTE ACHAT PETIT POIDS TALPE	7	2	433	321456	98745	55000.00	\N	2026-09-10 14:39:59.58702+00
456	1261	2026-09-10	SOLDE FACTURE (CHU)	OISA	7	2	433	321457	PC-0088	27500.00	\N	2026-09-10 14:44:28.734043+00
457	1261	2026-09-10	ACHAT CARBURANT	Plein MASSA	8	\N	433	\N	98653	32000.00	\N	2026-09-10 14:46:06.689964+00
380	1080	2026-09-07	Achat de produit laitier	Achat de produit laitier	7	2	433	213596	87456	256000.00	247	2026-09-07 11:24:33.270951+00
381	1080	2026-09-07	Entretient bureau	ACHAT POUR BUREAUX	11	\N	433	\N	5987	1950.00	\N	2026-09-07 11:40:31.33428+00
382	1080	2026-09-07	ACHAT BOSS	ACHAT BOSS	13	\N	433	\N	22548	1500.00	\N	2026-09-07 11:41:54.014254+00
383	1080	2026-09-07	GONFLET PNEU	MASSA	13	\N	433	\N	547896	500.00	\N	2026-09-07 11:43:02.553915+00
384	1080	2026-09-07	ACHAT DE RIZ	ACHAT DE RIZ	7	2	433	234040	234047	480000.00	248	2026-09-07 11:50:55.943216+00
85	271	2026-09-03	PANZANI OUEST AFRIC	ACHAT DE SPAGUETTI PANZANI	7	4	433	0015144	213254	9500.00	\N	2026-09-03 07:51:28.861992+00
86	271	2026-09-03	ACHAT SENTINELLE	ACHAT SENTINELLE	7	3	433	0456178	PC-001	50000.00	\N	2026-09-03 09:18:42.663913+00
87	271	2026-09-03	ACHAT YAOURT VIGORT	ACHAT YAOURT VIGORT	7	3	433	0471602	00124	20000.00	\N	2026-09-03 10:05:14.89875+00
147	370	2026-09-04	ACHAT EAU AWA	ACHAT EAU AWA	7	4	433	589647	P-008	153200.00	62	2026-09-04 15:25:58.936934+00
148	370	2026-09-04	COMPLEMENT SIPROCHIME	COMPLEMENT SIPROCHIME	7	1	433	A758659	9626229	60000.00	\N	2026-09-04 15:28:32.486418+00
149	370	2026-09-04	TRANSPORT JULIE	Transport achat	8	\N	433	\N	899559	4950.00	\N	2026-09-04 15:33:01.762185+00
654	1949	2026-10-07	ACHAT DE RIZ	Achat de riz	7	4	433	145698	CAISSE PRINCIPALE	435000.00	513	2026-10-07 10:58:43.677793+00
94	271	2026-09-03	TRANSPORT	TRANSPORT	8	\N	433	\N	PC-005	5000.00	\N	2026-09-03 11:38:13.888256+00
162	451	2026-09-05	ACHAT DE SPAGUETTI PANZANI	ACHAT DE SPAGUETTI PANZANI	7	4	433	5896284	875	65000.00	\N	2026-09-05 17:59:55.991473+00
400	1136	2026-09-08	ACHAT YAOUT	ACHAT YAOUT	7	4	433	64854	36195	59950.00	\N	2026-09-08 14:13:26.205043+00
401	1136	2026-09-08	REGLEMENT PARTIEL DU PERSONNEL	REGLEMENT PARTIEL DU PERSONNEL	13	\N	433	\N	254365	220000.00	264	2026-09-08 14:20:16.459555+00
109	271	2026-09-03	ACHAT MARCHE	ACHAT MARCHE	15	\N	433	\N	P-008	65000.00	\N	2026-09-03 15:26:10.352211+00
402	1136	2026-09-08	PARTICIPATION N'ZIANOUAN ACHAT BATTERIE	PARTICIPATION N'ZIANOUAN ACHAT BATTERIE	13	\N	433	\N	632145	14000.00	\N	2026-09-08 14:21:04.742741+00
403	1136	2026-09-08	ACHAT SAUCISSON N'ZIANOUAN	ACHAT SAUCISSON N'ZIANOUAN	7	1	433	3596	9854	42200.00	\N	2026-09-08 14:23:04.812471+00
404	1136	2026-09-08	ACHAT SAUCISSON	ACHAT SAUCISSON	7	1	433	78459	96321	10000.00	\N	2026-09-08 14:23:55.987288+00
405	1136	2026-09-08	ACHAT TEA	ACHAT TEA	7	4	433	3652	9874	11500.00	\N	2026-09-08 14:25:19.028501+00
406	1136	2026-09-08	SALAMI NASSREDINE ALI	ACHAT HUILE D'OLIVE	7	4	433	123456	654123	22000.00	\N	2026-09-08 14:26:58.299692+00
414	1136	2026-09-08	ACPTE ACHAT PETIT POIDS TALPE	ACPTE ACHAT PETIT POIDS TALPE	7	2	433	12369	9632	50000.00	\N	2026-09-08 14:54:46.919313+00
415	1136	2026-09-08	TRANSPORT MARCHANDISE	TRANSPORT MARCHANDISE pour N'ZIANOUA	8	\N	433	\N	213587	12500.00	\N	2026-09-08 14:56:26.417447+00
416	1136	2026-09-08	ACHAT D'EAU CELESTE	ACHAT D'EAU CELESTE	7	3	433	789654	3698	44300.00	\N	2026-09-08 15:00:08.128575+00
417	1136	2026-09-08	COMPLEMENT ACHAT MACHE	COMPLEMENT ACHAT MACHE	13	\N	433	\N	32459	51000.00	\N	2026-09-08 15:02:37.403866+00
418	1136	2026-09-08	ACPTE PROSUMA	ACPTE PROSUMA	7	4	433	9874	PC-002	63850.00	\N	2026-09-08 15:08:24.074975+00
419	1136	2026-09-08	ENTRETIENT	ENTRETIENT BUREAU BOSS	11	\N	433	\N	87965	20000.00	\N	2026-09-08 15:17:08.056519+00
607	1752	2026-09-28	ACHAT DE RIZ	Achat de riz	7	1	433	321456987	\N	450000.00	467	2026-09-28 11:42:02.747339+00
653	1949	2026-10-07	Achat poulet	Achat poulet	7	1	433	865479	CAISSE PRINCIPALE	45000.00	\N	2026-10-07 10:24:59.831858+00
\.


--
-- Data for Name: operations_encaissement; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.operations_encaissement (id, caisse_journee_id, type_encaissement, date_operation, libelle, montant, executant_id, n_bon_caisse, created_at) FROM stdin;
131	270	vente	2026-09-02	Vente du jour	323000.00	433	\N	2026-09-02 11:44:51.463878+00
132	271	approvisionnement	2026-09-03	RETOUR MONNAIE / ACHAT MARCHE	3250.00	433	\N	2026-09-03 09:08:55.750291+00
133	271	vente	2026-09-03	Vente du Rose Monde	120000.00	433	\N	2026-09-03 09:11:51.162986+00
576	1949	approvisionnement	2026-10-07	RETOUR MONNAIE / ACHAT MARCHE	15000.00	433	\N	2026-10-07 12:23:30.519836+00
397	1080	approvisionnement	2026-09-07	RETOUR MONNAIE / ACHAT MARCHE	35000.00	433	\N	2026-09-07 11:30:35.897144+00
398	1080	vente	2026-09-07	Vente du jour	520000.00	433	\N	2026-09-07 11:46:09.553044+00
409	1136	vente	2026-09-08	Vente du jour	755000.00	433	\N	2026-09-08 14:29:59.474735+00
412	1136	vente	2026-09-08	Vente du jour	150000.00	433	\N	2026-09-08 15:01:25.233734+00
223	451	vente	2026-09-05	Vente du jour	350000.00	433	\N	2026-09-05 17:56:23.624988+00
551	1752	approvisionnement	2026-09-28	RETOUR MONNAIE / ACHAT MARCHE	75000.00	433	\N	2026-09-28 12:01:59.335515+00
184	370	vente	2026-09-04	Vente du jour	520000.00	433	\N	2026-09-04 14:40:33.543645+00
562	1752	vente	2026-09-28	Vente du jour	650000.00	433	\N	2026-09-28 12:09:25.226345+00
\.


--
-- Data for Name: order_items; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.order_items (id, order_id, product_id, product_name_snapshot, category_snapshot, unit_price_xof, quantity, vat_rate, line_total_xof, note, added_by_user_id, added_at, removed_at, removed_by_user_id, removal_reason, created_at, updated_at) FROM stdin;
886a1abb-1324-4132-ab3d-d85de26466f7	03f1433e-f79b-47f1-923c-55a1b3061ef8	934dde37-9033-45e6-86ed-7cdd2215b18e	Kabato Dah + Poulet	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:28.782276+00	\N	\N	\N	2026-10-29 15:51:28.785307+00	2026-10-29 15:51:28.785318+00
fe43491c-8379-4c80-9019-4980d9ea4046	03f1433e-f79b-47f1-923c-55a1b3061ef8	2c470520-ac57-4c94-bc51-2e952fe1ab21	Kabato Dah + Poisson	Spécial Kabato	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:28.951814+00	\N	\N	\N	2026-10-29 15:51:28.952713+00	2026-10-29 15:51:28.952723+00
b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec	03f1433e-f79b-47f1-923c-55a1b3061ef8	f8c3551b-ce83-449e-a6c1-a640f89e8e68	Kabato Kope + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:29.068179+00	\N	\N	\N	2026-10-29 15:51:29.068858+00	2026-10-29 15:51:29.068867+00
f6516bfe-a30a-4469-a223-235df3a1cf4f	03f1433e-f79b-47f1-923c-55a1b3061ef8	3b88851d-6135-478b-ae23-72cdc60db21c	Kabato Dah + Bœuf	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:29.187982+00	\N	\N	\N	2026-10-29 15:51:29.188582+00	2026-10-29 15:51:29.18859+00
651ad9da-668d-41ca-98bd-fd5c693b36af	03f1433e-f79b-47f1-923c-55a1b3061ef8	e2551239-6d21-4a43-aac3-f435b261884e	Frites + Boeuf	Spécial Ivoirienne	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:29.289532+00	\N	\N	\N	2026-10-29 15:51:29.29009+00	2026-10-29 15:51:29.290096+00
c33981ba-c745-446d-99bd-efccdca207da	03f1433e-f79b-47f1-923c-55a1b3061ef8	46a09e73-28f4-4df9-984a-95ac939cfe1a	Attiéké + Poulet	Spécial Ivoirienne	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:29.390459+00	\N	\N	\N	2026-10-29 15:51:29.391222+00	2026-10-29 15:51:29.391233+00
4d790f5e-2f4b-4210-b0a6-eefb52b3e773	03f1433e-f79b-47f1-923c-55a1b3061ef8	28e30eaa-c921-4371-8e7e-f0c7d3d1e011	Alloco + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:29.496034+00	\N	\N	\N	2026-10-29 15:51:29.496746+00	2026-10-29 15:51:29.496755+00
2529e749-aa73-40b1-9478-8e0738879f53	03f1433e-f79b-47f1-923c-55a1b3061ef8	e328a67e-40df-4b18-903d-a5938ad83d56	Petit pois + Bœuf	Spécial Ivoirienne	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:29.601496+00	\N	\N	\N	2026-10-29 15:51:29.602111+00	2026-10-29 15:51:29.602118+00
b5f69c09-9d24-4966-82fc-2f95a163bfb1	03f1433e-f79b-47f1-923c-55a1b3061ef8	4f4a6067-f359-4422-bbbb-20f5aaded6b3	Petit pois + Sosso 3500	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:51:29.71953+00	\N	\N	\N	2026-10-29 15:51:29.720154+00	2026-10-29 15:51:29.720164+00
c03f81d8-1777-4c8b-9c91-8c0690d4555a	4df61102-c27c-4879-8ed2-15b88304cd09	fbb74d1d-e719-4478-b4fb-df4a903e41d5	Kabato Kope + Poulet	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:04.19666+00	\N	\N	\N	2026-10-29 15:52:04.197423+00	2026-10-29 15:52:04.197434+00
b033f55d-efa9-4237-bbcc-a0a118c42d13	4df61102-c27c-4879-8ed2-15b88304cd09	2c470520-ac57-4c94-bc51-2e952fe1ab21	Kabato Dah + Poisson	Spécial Kabato	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:04.294964+00	\N	\N	\N	2026-10-29 15:52:04.295764+00	2026-10-29 15:52:04.295772+00
32cf20d8-7aad-47df-a0bd-9577a68f574c	4df61102-c27c-4879-8ed2-15b88304cd09	f8c3551b-ce83-449e-a6c1-a640f89e8e68	Kabato Kope + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:04.402631+00	\N	\N	\N	2026-10-29 15:52:04.403574+00	2026-10-29 15:52:04.403593+00
b0d9289b-e7f3-44f7-9bc4-2caad7472828	4df61102-c27c-4879-8ed2-15b88304cd09	e2551239-6d21-4a43-aac3-f435b261884e	Frites + Boeuf	Spécial Ivoirienne	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:04.491957+00	\N	\N	\N	2026-10-29 15:52:04.492873+00	2026-10-29 15:52:04.492881+00
bb293b3e-c92f-49b7-9263-6bab906285f9	4df61102-c27c-4879-8ed2-15b88304cd09	dbf93f42-7b4c-4c7e-a873-10f18a2151b0	Igname frite + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:04.578479+00	\N	\N	\N	2026-10-29 15:52:04.57907+00	2026-10-29 15:52:04.579077+00
023cf862-5641-4a2e-b690-00429131a979	4df61102-c27c-4879-8ed2-15b88304cd09	fac18978-1efd-4b64-99a7-75758a3d73c6	Attiéké + Boeuf	Spécial Ivoirienne	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:04.666432+00	\N	\N	\N	2026-10-29 15:52:04.666823+00	2026-10-29 15:52:04.666827+00
b3526943-6b8d-4a08-9516-18f61ad84c12	4df61102-c27c-4879-8ed2-15b88304cd09	1dcc3350-2fdb-4653-a60f-ec1212bb682e	Alloco + Poulet	Spécial Ivoirienne	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:04.754228+00	\N	\N	\N	2026-10-29 15:52:04.75511+00	2026-10-29 15:52:04.755121+00
88811e0e-bea9-4939-a16d-7456e20b1d2e	4df61102-c27c-4879-8ed2-15b88304cd09	e328a67e-40df-4b18-903d-a5938ad83d56	Petit pois + Bœuf	Spécial Ivoirienne	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:04.837171+00	\N	\N	\N	2026-10-29 15:52:04.838512+00	2026-10-29 15:52:04.838522+00
52cacaa5-7d53-41fe-8e84-616f049e5043	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	fae9bc78-c632-44ec-a196-9e9f7f970fa0	Igname bouillie + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:13.002438+00	\N	\N	\N	2026-10-29 16:33:13.004947+00	2026-10-29 16:33:13.004957+00
5884e7fb-f015-4316-8833-f3da0c3ddeed	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	fac18978-1efd-4b64-99a7-75758a3d73c6	Attiéké + Boeuf	Spécial Ivoirienne	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:13.124249+00	\N	\N	\N	2026-10-29 16:33:13.125598+00	2026-10-29 16:33:13.125611+00
53813ee6-0602-4f66-88d0-bb3079b78275	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	7e2e9acc-4cb0-4222-8e04-e09402820956	Alloco + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:13.245798+00	\N	\N	\N	2026-10-29 16:33:13.246779+00	2026-10-29 16:33:13.246788+00
10da25f8-2495-4165-b908-37c7fd9f821b	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	da7a9d7b-64d7-46e9-9a66-fb411d1976e5	Salade Panachée + Poulet	Spécial Salade	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:13.398427+00	\N	\N	\N	2026-10-29 16:33:13.39928+00	2026-10-29 16:33:13.39929+00
6b6248ae-cd37-4b18-a89b-f73c403b9622	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	9730e484-0913-497b-8663-b228822b3ddc	Salade Fraîche + Poulet	Spécial Salade	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:13.504952+00	\N	\N	\N	2026-10-29 16:33:13.505703+00	2026-10-29 16:33:13.505712+00
a36043cf-1af4-4f12-a5d3-28386af12cdc	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	93b1f693-b2ca-4ca6-8abd-bbd9abcfd971	Salade Fraîche + Sosso 4000	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:13.620768+00	\N	\N	\N	2026-10-29 16:33:13.621674+00	2026-10-29 16:33:13.621685+00
44233049-ad0f-420f-9fc7-c94a58dba425	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	df2a62c3-58d6-430f-b10e-45b0cb58cff1	Salade Panachée + Sosso 5000	Spécial Salade	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:13.731553+00	\N	\N	\N	2026-10-29 16:33:13.732447+00	2026-10-29 16:33:13.73246+00
1b705b20-098e-4504-8b97-1b53a198a141	dcedcffe-336a-4484-988f-b28e1a2e7ba0	e0648d5b-df64-444f-82cf-0d18b472b3db	Sosso 3500	Poissons	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:44.74406+00	\N	\N	\N	2026-10-29 16:33:44.745148+00	2026-10-29 16:33:44.745158+00
1b32cc23-9ad8-4a45-97c9-fb91c0d24abb	dcedcffe-336a-4484-988f-b28e1a2e7ba0	93418cf7-cec2-4441-925a-2917ba67479a	Sosso 7000	Poissons	7000	1	0.00	7000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:44.890289+00	\N	\N	\N	2026-10-29 16:33:44.891251+00	2026-10-29 16:33:44.891262+00
ddc6864b-3904-41f3-9f3a-b791af71aedc	dcedcffe-336a-4484-988f-b28e1a2e7ba0	fbb74d1d-e719-4478-b4fb-df4a903e41d5	Kabato Kope + Poulet	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:45.061905+00	\N	\N	\N	2026-10-29 16:33:45.062769+00	2026-10-29 16:33:45.062785+00
34a0bc05-7144-4cf4-b542-2edb6a271273	dcedcffe-336a-4484-988f-b28e1a2e7ba0	78a775c5-9a24-4760-a370-483ebc35cd3d	Kabato Lafri + Boeuf	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:45.194067+00	\N	\N	\N	2026-10-29 16:33:45.195027+00	2026-10-29 16:33:45.19504+00
cf4f9468-9d80-4cd0-a28f-f3ea46ac8ff2	dcedcffe-336a-4484-988f-b28e1a2e7ba0	3acf88aa-9368-4a0b-a967-3e79d26c59dc	Kabato Dah + Boeuf	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:45.323293+00	\N	\N	\N	2026-10-29 16:33:45.324264+00	2026-10-29 16:33:45.324279+00
db889a3d-91e0-478f-ba4e-e266bcdccd46	dcedcffe-336a-4484-988f-b28e1a2e7ba0	e187c501-7b39-497d-95d8-832d0aa0ac66	Kabato Lafri + Mouton	Spécial Kabato	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:45.425736+00	\N	\N	\N	2026-10-29 16:33:45.426704+00	2026-10-29 16:33:45.426717+00
8e61150a-5664-470a-8ae3-ee2f8a2bdb4d	dcedcffe-336a-4484-988f-b28e1a2e7ba0	19a0e1b1-b889-4cf6-b553-017f739929aa	Couscous + Poulet	Spécial Oriental	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:45.540079+00	\N	\N	\N	2026-10-29 16:33:45.540818+00	2026-10-29 16:33:45.540829+00
3ff47e3f-82e6-45f4-8ae4-a4e854c07bcc	dcedcffe-336a-4484-988f-b28e1a2e7ba0	cd408593-401c-46d0-8507-624f0342f05a	Couscous + Poisson	Spécial Oriental	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:45.637192+00	\N	\N	\N	2026-10-29 16:33:45.637804+00	2026-10-29 16:33:45.637811+00
96301ae0-6da5-4801-81e0-e95b2025e5c6	dcedcffe-336a-4484-988f-b28e1a2e7ba0	e2028931-16ad-47cd-a58c-03359d67788d	Couscous + Mouton	Spécial Oriental	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:45.736705+00	\N	\N	\N	2026-10-29 16:33:45.737635+00	2026-10-29 16:33:45.737647+00
ea48c73b-7797-4838-9f2f-ecc20058df81	05ad026a-7ca3-47fe-a3c6-93ca6b508870	f2ceb9f5-5bbe-4b7d-8f8d-87fa4e9cc0db	Kabato Kope + Boeuf	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:03:47.859307+00	\N	\N	\N	2026-10-30 11:03:47.862566+00	2026-10-30 11:03:47.862575+00
079270e7-fdd9-47c8-ae6e-580f83a4d0ed	1b4709eb-7431-4782-8ff3-bd821ed4b2ec	f2ceb9f5-5bbe-4b7d-8f8d-87fa4e9cc0db	Kabato Kope + Boeuf	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:10:11.948983+00	\N	\N	\N	2026-10-30 11:10:11.949558+00	2026-10-30 11:10:11.949565+00
ae8c1b03-97ca-4fca-b599-b62195f3cd51	c9bc61b4-ad71-4a9f-93c6-918d772fb438	d354b5f0-e3a9-4024-9a11-6524de50706c	Foutou + Pistache poisson	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:00.964641+00	\N	\N	\N	2026-10-30 11:12:00.965297+00	2026-10-30 11:12:00.965305+00
70224647-ff1a-405c-844c-62c1b1d3130b	c9bc61b4-ad71-4a9f-93c6-918d772fb438	8b637a4c-48a2-4b14-b5c5-e233a972a424	Foutou gouagouassou + Mouton	Foufou / foutou	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:01.063729+00	\N	\N	\N	2026-10-30 11:12:01.064466+00	2026-10-30 11:12:01.064473+00
a585b556-87e4-4302-8160-a2a342eb99d4	c9bc61b4-ad71-4a9f-93c6-918d772fb438	ab541db9-d472-4db5-b3aa-ffc75fb46468	Foutou gouagouassou + Poisson	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:01.172335+00	\N	\N	\N	2026-10-30 11:12:01.173011+00	2026-10-30 11:12:01.173018+00
6099bd33-f0d3-42ed-ad6b-c13d3f74e1fe	c9bc61b4-ad71-4a9f-93c6-918d772fb438	0ae6808c-7e1e-49f0-856a-ebfe2232965b	Foutou gouagouassou + Poulet	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:01.269168+00	\N	\N	\N	2026-10-30 11:12:01.269751+00	2026-10-30 11:12:01.269756+00
de335dd4-55c1-44a5-9a9e-569dcec3f62f	c9bc61b4-ad71-4a9f-93c6-918d772fb438	3711b33e-f1bf-4416-91ea-5a85e467fe7b	Foutou graine + Bœuf	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:01.352087+00	\N	\N	\N	2026-10-30 11:12:01.352733+00	2026-10-30 11:12:01.352739+00
d62d4f89-0e16-482e-ae46-95334f9006c5	c9bc61b4-ad71-4a9f-93c6-918d772fb438	17f0a5d7-b947-44af-8d36-5d17846b8fe8	Foutou graine + Mouton	Foufou / foutou	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:01.428556+00	\N	\N	\N	2026-10-30 11:12:01.429068+00	2026-10-30 11:12:01.429072+00
30da91b1-bd3a-4ffe-9a86-f0ffb4e157b8	c9bc61b4-ad71-4a9f-93c6-918d772fb438	176b9a0f-e557-43fa-8d36-5b111810a5e2	Foutou graine + Poulet	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:01.50972+00	\N	\N	\N	2026-10-30 11:12:01.51016+00	2026-10-30 11:12:01.510165+00
8cc4a9e5-1b4f-4342-a8a2-1d1bb8419de8	ff8f5b34-95af-4d39-90dd-2308a7d41876	ceafb668-7cd6-4c8f-90cd-f44a62dc5c26	Foufou/foutou bœuf	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:32:36.947243+00	\N	\N	\N	2026-10-30 11:32:36.949599+00	2026-10-30 11:32:36.94961+00
0289f245-63b2-4ce2-8774-924e3a3d5727	ff8f5b34-95af-4d39-90dd-2308a7d41876	bfee22fc-f027-48c3-92af-f2f2f6e6145b	Foufou/foutou poulet	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:32:37.052083+00	\N	\N	\N	2026-10-30 11:32:37.052985+00	2026-10-30 11:32:37.052998+00
81f15313-d890-43b7-8a5f-2d6abacf0299	ff8f5b34-95af-4d39-90dd-2308a7d41876	c0fd4f28-d8a7-45db-9637-1ad10947cba0	Foufou sauce claire + Bœuf	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:32:37.175306+00	\N	\N	\N	2026-10-30 11:32:37.175937+00	2026-10-30 11:32:37.175947+00
080cefe1-d22d-4e91-984b-b20f3dcc7992	ff8f5b34-95af-4d39-90dd-2308a7d41876	578fbb1b-8dea-4372-919e-464656bcc8e4	Foufou sauce claire + Poulet	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:32:37.257277+00	\N	\N	\N	2026-10-30 11:32:37.257948+00	2026-10-30 11:32:37.257956+00
\.


--
-- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.orders (id, order_number, cash_session_id, table_id, status, opened_by_user_id, closed_by_user_id, guests_count, total_ttc_xof, total_ht_xof, total_vat_xof, paid_xof, due_xof, cancelled_reason, cancelled_by_user_id, cancelled_at, opened_at, paid_at, created_at, updated_at, note_label) FROM stdin;
c9bc61b4-ad71-4a9f-93c6-918d772fb438	2026-10-30-0003	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	830e098a-77ec-4022-8736-ed94c5fe3cfe	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	25500	25500	0	25500	0	\N	\N	\N	2026-10-30 11:12:00.869434+00	2026-10-30 11:12:16.07378+00	2026-10-30 11:12:00.870472+00	2026-10-30 11:12:16.150586+00	Note 1
ff8f5b34-95af-4d39-90dd-2308a7d41876	2026-10-30-0004	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	cb2c0d43-facf-4ddc-bda4-b99afa2ec289	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	14000	14000	0	14000	0	\N	\N	\N	2026-10-30 11:32:36.848704+00	2026-10-30 11:32:46.316268+00	2026-10-30 11:32:36.851174+00	2026-10-30 11:32:46.349497+00	Note 1
dcedcffe-336a-4484-988f-b28e1a2e7ba0	2026-10-29-0004	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	830e098a-77ec-4022-8736-ed94c5fe3cfe	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	33500	33500	0	33500	0	\N	\N	\N	2026-10-29 16:33:44.620144+00	2026-10-29 16:33:55.755378+00	2026-10-29 16:33:44.621146+00	2026-10-29 16:33:55.816599+00	Note 1
786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	2026-10-29-0003	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	47e6e141-b494-4813-8c9c-3c455c91a422	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	26000	26000	0	26000	0	\N	\N	\N	2026-10-29 16:33:12.848838+00	2026-10-29 16:34:14.31678+00	2026-10-29 16:33:12.852726+00	2026-10-29 16:34:14.344672+00	Note 1
05ad026a-7ca3-47fe-a3c6-93ca6b508870	2026-10-30-0001	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	3000	3000	0	3000	0	\N	\N	\N	2026-10-30 11:03:22.762423+00	2026-10-30 11:05:12.009506+00	2026-10-30 11:03:22.779114+00	2026-10-30 11:05:12.075556+00	Note 1
03f1433e-f79b-47f1-923c-55a1b3061ef8	2026-10-29-0001	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	30000	30000	0	30000	0	\N	\N	\N	2026-10-29 15:51:28.643693+00	2026-10-29 15:52:41.628958+00	2026-10-29 15:51:28.65153+00	2026-10-29 15:52:41.69743+00	Note 1
4df61102-c27c-4879-8ed2-15b88304cd09	2026-10-29-0002	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	25000	25000	0	25000	0	\N	\N	\N	2026-10-29 15:51:48.42075+00	2026-10-29 15:53:45.893407+00	2026-10-29 15:51:48.421409+00	2026-10-29 15:53:45.918506+00	Note 2
1b4709eb-7431-4782-8ff3-bd821ed4b2ec	2026-10-30-0002	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	47e6e141-b494-4813-8c9c-3c455c91a422	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	3000	3000	0	3000	0	\N	\N	\N	2026-10-30 11:10:11.85717+00	2026-10-30 11:10:16.613274+00	2026-10-30 11:10:11.858151+00	2026-10-30 11:10:16.650832+00	Note 1
\.


--
-- Data for Name: outbox_events; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.outbox_events (id, event_type, aggregate_type, aggregate_id, payload, status, retry_count, next_retry_at, last_error, processed_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.payments (id, order_id, cash_session_id, user_id, method, amount_xof, tendered_xof, change_xof, provider, reference, status, idempotency_key, created_at, updated_at) FROM stdin;
36ef37f6-2243-41bf-b2bf-e6a4f04c251b	03f1433e-f79b-47f1-923c-55a1b3061ef8	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	30000	30000	0	\N	\N	CAPTURED	pay-03f1433e-f79b-47f1-923c-55a1b3061ef8-1793289161573-ef3m3pb	2026-10-29 15:52:41.618147+00	2026-10-29 15:52:41.618157+00
af169dc1-29a2-4501-8f71-1bbe83177f2e	4df61102-c27c-4879-8ed2-15b88304cd09	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	25000	25000	0	\N	\N	CAPTURED	pay-4df61102-c27c-4879-8ed2-15b88304cd09-1793289225842-1dags7e	2026-10-29 15:53:45.885314+00	2026-10-29 15:53:45.885324+00
8716e1cf-8b3e-4a32-aeb2-19664ccb9ae7	dcedcffe-336a-4484-988f-b28e1a2e7ba0	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	33500	33500	0	\N	\N	CAPTURED	pay-dcedcffe-336a-4484-988f-b28e1a2e7ba0-1793291635696-nx5rmin	2026-10-29 16:33:55.740526+00	2026-10-29 16:33:55.740537+00
7aeb51d0-f90a-45b0-9577-87bb37396bb8	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	43b1ef8c-dd0c-4dd7-964c-f3e20bb9d20a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	26000	26000	0	\N	\N	CAPTURED	pay-786345a5-e9b2-4ac6-89f4-4397ba8b4fa7-1793291654272-jgzy9bm	2026-10-29 16:34:14.307852+00	2026-10-29 16:34:14.307861+00
ece75c3c-3e70-41d0-bb85-cdf0d7ca0cbf	05ad026a-7ca3-47fe-a3c6-93ca6b508870	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	3000	3000	0	\N	\N	CAPTURED	pay-05ad026a-7ca3-47fe-a3c6-93ca6b508870-1793358311927-66t1wsn	2026-10-30 11:05:11.993773+00	2026-10-30 11:05:11.993787+00
a00ab204-76cc-41e3-a653-4bca4eb1fa69	1b4709eb-7431-4782-8ff3-bd821ed4b2ec	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	3000	3000	0	\N	\N	CAPTURED	pay-1b4709eb-7431-4782-8ff3-bd821ed4b2ec-1793358616553-m6iajo8	2026-10-30 11:10:16.594968+00	2026-10-30 11:10:16.594986+00
b435a1c1-0b7b-44df-8887-03062f0e071c	c9bc61b4-ad71-4a9f-93c6-918d772fb438	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	25500	30000	4500	\N	\N	CAPTURED	pay-c9bc61b4-ad71-4a9f-93c6-918d772fb438-1793358736017-0adwpxo	2026-10-30 11:12:16.062962+00	2026-10-30 11:12:16.062974+00
684a5a0a-b655-4e10-89ae-6c1654c74a77	ff8f5b34-95af-4d39-90dd-2308a7d41876	e392e6cf-0283-47b9-b17f-c0400f0f0a6f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	14000	14000	0	\N	\N	CAPTURED	pay-ff8f5b34-95af-4d39-90dd-2308a7d41876-1793359966275-t79p6i2	2026-10-30 11:32:46.307774+00	2026-10-30 11:32:46.307783+00
\.


--
-- Data for Name: print_jobs; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.print_jobs (id, order_id, job_type, status, content, open_drawer, cut, is_duplicate, error_message, printed_at, created_at, updated_at, claimed_at, terminal_id, attempts) FROM stdin;
d2f9eca5-d91c-417b-800c-b74f1354e0a4	03f1433e-f79b-47f1-923c-55a1b3061ef8	RECEIPT	QUEUED	        Abidjan, Plateau        \n      Tel: +225 0102030405      \n         NCC: 1234567A          \n    RCCM: CI-ABJ-2026-B-0000    \n--------------------------------\nTicket :         2026-10-29-0001\nTable : Table 3     Couverts : 4\nCaissier : Digui Thio\n                29/10/2026 15:52\n--------------------------------\n1x Kabato Dah +\n  Poulet              3 000 FCFA\n1x Kabato Dah +\n  Poisson             3 500 FCFA\n1x Kabato Kope +\n  Poisson             3 000 FCFA\n1x Kabato Dah + Boeuf 3 000 FCFA\n1x Frites + Boeuf     3 000 FCFA\n1x Attiéké + Poulet   3 000 FCFA\n1x Alloco +\n  Poisson braisé      5 000 FCFA\n1x Petit pois + Boeuf 3 000 FCFA\n1x Petit pois +\n  Sosso 3500          3 500 FCFA\n\nTOTAL TTC            30 000 FCFA\nReglement Especes :  30 000 FCFA\n--------------------------------\n Merci de votre visite  a très  \n           bientôt !            	t	t	f	\N	\N	2026-10-29 15:52:41.701664+00	2026-10-29 15:52:41.701672+00	\N	\N	0
a852790d-f472-4836-aab8-56a0e88ba550	4df61102-c27c-4879-8ed2-15b88304cd09	RECEIPT	QUEUED	        Abidjan, Plateau        \n      Tel: +225 0102030405      \n         NCC: 1234567A          \n    RCCM: CI-ABJ-2026-B-0000    \n--------------------------------\nTicket :         2026-10-29-0002\nTable : Table 3     Couverts : 1\nCaissier : Digui Thio\n                29/10/2026 15:53\n--------------------------------\n1x Kabato Kope +\n  Poulet              3 000 FCFA\n1x Kabato Dah +\n  Poisson             3 500 FCFA\n1x Kabato Kope +\n  Poisson             3 000 FCFA\n1x Frites + Boeuf     3 000 FCFA\n1x Igname frite +\n  Mouton              3 500 FCFA\n1x Attiéké + Boeuf    3 000 FCFA\n1x Alloco + Poulet    3 000 FCFA\n1x Petit pois + Boeuf 3 000 FCFA\n\nTOTAL TTC            25 000 FCFA\nReglement Especes :  25 000 FCFA\n--------------------------------\n Merci de votre visite  a très  \n           bientôt !            	t	t	f	\N	\N	2026-10-29 15:53:45.920184+00	2026-10-29 15:53:45.920191+00	\N	\N	0
1c37e935-f274-4360-aa93-3f074c70a32a	dcedcffe-336a-4484-988f-b28e1a2e7ba0	RECEIPT	QUEUED	        Abidjan, Plateau        \n      Tel: +225 0102030405      \n         NCC: 1234567A          \n    RCCM: CI-ABJ-2026-B-0000    \n--------------------------------\nTicket :         2026-10-29-0004\nTable : Table 4     Couverts : 4\nCaissier : Digui Thio\n                29/10/2026 16:33\n--------------------------------\n1x Sosso 3500         3 500 FCFA\n1x Sosso 7000         7 000 FCFA\n1x Kabato Kope +\n  Poulet              3 000 FCFA\n1x Kabato Lafri +\n  Boeuf               3 000 FCFA\n1x Kabato Dah + Boeuf 3 000 FCFA\n1x Kabato Lafri +\n  Mouton              3 500 FCFA\n1x Couscous + Poulet  3 000 FCFA\n1x Couscous + Poisson 3 500 FCFA\n1x Couscous + Mouton  4 000 FCFA\n\nTOTAL TTC            33 500 FCFA\nReglement Especes :  33 500 FCFA\n--------------------------------\n Merci de votre visite  a très  \n           bientôt !            	t	t	f	\N	\N	2026-10-29 16:33:55.821278+00	2026-10-29 16:33:55.821289+00	\N	\N	0
eb25f8f8-8b25-4cc3-a4f2-c3d2885fab9a	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	RECEIPT	QUEUED	        Abidjan, Plateau        \n      Tel: +225 0102030405      \n         NCC: 1234567A          \n    RCCM: CI-ABJ-2026-B-0000    \n--------------------------------\nTicket :         2026-10-29-0003\nTable : Table 2     Couverts : 4\nCaissier : Digui Thio\n                29/10/2026 16:34\n--------------------------------\n1x Igname bouillie +\n  Sosso               4 000 FCFA\n1x Attiéké + Boeuf    3 000 FCFA\n1x Alloco + Sosso     4 000 FCFA\n1x Salade Panachée +\n  Poulet              3 000 FCFA\n1x Salade Fraîche +\n  Poulet              3 000 FCFA\n1x Salade Fraîche +\n  Sosso 4000          4 000 FCFA\n1x Salade Panachée +\n  Sosso 5000          5 000 FCFA\n\nTOTAL TTC            26 000 FCFA\nReglement Especes :  26 000 FCFA\n--------------------------------\n Merci de votre visite  a très  \n           bientôt !            	t	t	f	\N	\N	2026-10-29 16:34:14.347247+00	2026-10-29 16:34:14.347257+00	\N	\N	0
da4445ef-905a-4d96-b5cf-65a73bb5ee99	05ad026a-7ca3-47fe-a3c6-93ca6b508870	RECEIPT	QUEUED	        Abidjan, Plateau        \n      Tel: +225 0102030405      \n         NCC: 1234567A          \n    RCCM: CI-ABJ-2026-B-0000    \n--------------------------------\nTicket :         2026-10-30-0001\nTable : Table 3     Couverts : 1\nCaissier : Digui Thio\n                30/10/2026 11:05\n--------------------------------\n1x Kabato Kope +\n  Boeuf               3 000 FCFA\n\nTOTAL TTC             3 000 FCFA\nReglement Especes :   3 000 FCFA\n--------------------------------\n Merci de votre visite  a très  \n           bientôt !            	t	t	f	\N	\N	2026-10-30 11:05:12.081226+00	2026-10-30 11:05:12.081237+00	\N	\N	0
0c75c0f8-c504-4623-accf-fea75dba276e	1b4709eb-7431-4782-8ff3-bd821ed4b2ec	RECEIPT	QUEUED	        Abidjan, Plateau        \n      Tel: +225 0102030405      \n         NCC: 1234567A          \n    RCCM: CI-ABJ-2026-B-0000    \n--------------------------------\nTicket :         2026-10-30-0002\nTable : Table 2     Couverts : 4\nCaissier : Digui Thio\n                30/10/2026 11:10\n--------------------------------\n1x Kabato Kope +\n  Boeuf               3 000 FCFA\n\nTOTAL TTC             3 000 FCFA\nReglement Especes :   3 000 FCFA\n--------------------------------\n Merci de votre visite  a très  \n           bientôt !            	t	t	f	\N	\N	2026-10-30 11:10:16.654792+00	2026-10-30 11:10:16.654808+00	\N	\N	0
65334c18-4710-4307-8b7d-0aef817c7d33	c9bc61b4-ad71-4a9f-93c6-918d772fb438	RECEIPT	QUEUED	        Abidjan, Plateau        \n      Tel: +225 0102030405      \n         NCC: 1234567A          \n    RCCM: CI-ABJ-2026-B-0000    \n--------------------------------\nTicket :         2026-10-30-0003\nTable : Table 4     Couverts : 4\nCaissier : Digui Thio\n                30/10/2026 11:12\n--------------------------------\n1x Foutou +\n  Pistache poisson    3 500 FCFA\n1x Foutou gouagouassou +\n  Mouton              4 000 FCFA\n1x Foutou gouagouassou +\n  Poisson             3 500 FCFA\n1x Foutou gouagouassou +\n  Poulet              3 500 FCFA\n1x Foutou graine +\n  Boeuf               3 500 FCFA\n1x Foutou graine +\n  Mouton              4 000 FCFA\n1x Foutou graine +\n  Poulet              3 500 FCFA\n\nTOTAL TTC            25 500 FCFA\nEspeces recues :     30 000 FCFA\nMonnaie rendue :      4 500 FCFA\n--------------------------------\n Merci de votre visite  a très  \n           bientôt !            	t	t	f	\N	\N	2026-10-30 11:12:16.154178+00	2026-10-30 11:12:16.154189+00	\N	\N	0
c2994709-d2ff-4293-8044-ed7c3b95990a	ff8f5b34-95af-4d39-90dd-2308a7d41876	RECEIPT	QUEUED	        Abidjan, Plateau        \n      Tel: +225 0102030405      \n         NCC: 1234567A          \n    RCCM: CI-ABJ-2026-B-0000    \n--------------------------------\nTicket :         2026-10-30-0004\nTable : Table 1     Couverts : 4\nCaissier : Digui Thio\n                30/10/2026 11:32\n--------------------------------\n1x Foufou/foutou\n  boeuf               3 500 FCFA\n1x Foufou/foutou\n  poulet              3 500 FCFA\n1x Foufou sauce claire +\n  Boeuf               3 500 FCFA\n1x Foufou sauce claire +\n  Poulet              3 500 FCFA\n\nTOTAL TTC            14 000 FCFA\nReglement Especes :  14 000 FCFA\n--------------------------------\n Merci de votre visite  a très  \n           bientôt !            	t	t	f	\N	\N	2026-10-30 11:32:46.353857+00	2026-10-30 11:32:46.353866+00	\N	\N	0
\.


--
-- Data for Name: print_terminals; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.print_terminals (id, name, token_hash, revoked_at, last_seen_at, printer_status, created_by, created_at, updated_at) FROM stdin;
b5e7a5f4-c84a-47e9-beed-cd584111ace2	Poste-Comptoir-1	969c58096e3d2d28b1b7b978605c8b1d324c4974badd928cefe1217f68edd094	\N	\N	{}	\N	2026-10-22 14:47:54.270727+00	2026-10-22 14:47:54.270734+00
\.


--
-- Data for Name: product_components; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.product_components (id, product_id, article_id, quantity) FROM stdin;
c2096991-1d5d-4dcc-852e-328cc50174bd	d06c79a2-0485-4ee2-bfc4-10d740c69241	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
dcb92c6f-802c-4274-9ca8-ba5a23c26a96	c56c3a9c-5317-4e3e-be7b-1bed326fe53f	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
713ce87a-45c4-49f3-b9c8-1addde0d1fdf	120dc3c0-0932-4219-94d7-01f56c5e1139	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
9619a0ea-6f56-4f6a-85b2-41d34f958c7a	ceafb668-7cd6-4c8f-90cd-f44a62dc5c26	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
abc02dfe-6769-47e7-9fc8-38b1bfafa3b2	11d8e671-0244-4066-854d-eede1fb90a58	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
1e063e19-e82f-427e-ac8a-c7df2c6e59e1	bfee22fc-f027-48c3-92af-f2f2f6e6145b	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
9df74bf7-d9e9-4826-8323-73294baf1420	f0dd6e5d-fc7f-4518-b2a4-731ef5de1bec	07ee94bb-1c62-4d20-b9e3-9b2aa9132f4a	0.250
9ed33649-30ca-4d8c-9ceb-8efd22281bba	601cc27a-9aad-4b65-935b-ec59b39a2e5b	258570a6-aee0-4adb-a7e1-526f56b06506	1.000
064e355a-c03c-44d4-9e09-2dd40ab37c32	01dbc122-a427-4ddb-ac94-6281b3301c7e	258570a6-aee0-4adb-a7e1-526f56b06506	1.000
3c258a84-05c6-4cd1-bf8f-680a7ac71ada	f2ed4eac-2031-4814-af66-619be36324f0	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
45ae2133-cef2-4d77-a69b-8d6cd27ed4be	e0648d5b-df64-444f-82cf-0d18b472b3db	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
ca5c7c9c-f43b-4840-85e7-115aa4f62912	9e31b16b-aac4-4431-9012-60dcc2e4e0d9	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
7ba58f96-2802-44c9-bb5c-782e992befff	23c6c6ec-ad5a-4626-8bfb-0076cf03534d	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
22bd3a18-5771-4a70-9e82-13955c2aa7e2	4f84df00-4f47-4ba8-b119-ea5e01d7d16c	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
c36cf8e4-ace1-4dea-8300-188cede436c5	c6ba2d3b-c3bd-42ba-b0d2-9adf3e1ad10f	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
24835efc-6be3-4a42-a635-256ba59e6ff5	53dbcb50-bebb-4593-9e98-27e713d3da4d	5e5c8e90-160b-4766-abc5-0b06087c6456	1.000
68f59f46-b1dc-4f6c-817b-336ff8f1dd38	5839313f-ebfa-478e-b99c-b79a1b75b313	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
72772e45-c613-413f-afe3-9f607c2779bc	6b776576-c91e-4151-b22b-d05e320b2f30	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
8bb34a2b-7dea-4755-980f-8175c8ae71ac	da028acf-3dee-46cb-a28d-60a205795865	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	1.000
dbe8903b-125f-4312-850d-238d95d3153c	882bccb2-37b1-4ce0-ae49-976744d001de	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	1.000
3555a851-f6c1-4c4b-8156-f1f073f93e88	9d0f0b4f-a32e-42f5-b23d-692d756cb566	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	1.000
4eb96771-f000-4b38-afd5-d4d48dca4c1a	be1c321d-e8ad-4910-b02e-412d149b7595	2cad3fbe-c8cf-4dc8-9a9c-3c39831d69e1	1.000
5f0fc126-9d7a-41b9-b37a-beebdcdfaddd	5cbd0c22-be56-429e-b0ea-07e3dd917763	d9fbe76f-9256-4c7e-9f98-5f9a1f4b0c3d	1.000
647ecc30-daf5-4d3d-9ce3-b713f276a979	00fc07e5-eee4-4d2b-afe7-a965d7a8ebb8	c3165735-9157-4879-b272-a6807c36d677	1.000
9d22ae89-1c0f-4040-9392-af1650f9ae39	60621b43-1544-48ec-ac29-4b90c955c8da	54d0c628-235d-4f09-b026-ab073c650261	1.000
07a3b5a1-b913-4f29-a9c7-32cd4fc4b6d8	c718be08-114b-480b-8367-75cb510147cd	25fd53a8-c277-418d-a596-b575ce7f784a	1.000
3acf636c-bd19-4a02-a965-d7820abe5584	b809a15b-9263-4a5e-8412-a09959a2c846	0edc867d-1dfa-4bdc-8988-8401299297b9	1.000
2c4c47ae-c936-4535-9640-17cdae35285d	a90e5445-f9cc-489a-8add-b74b9730ac84	fb615c0d-0da1-44bb-9a49-c1e3a3d772b2	1.000
8a29eba8-2831-4480-b9f7-ad64aa0342df	b09de5c7-8ea7-428e-ac90-6ae2d292dfff	b9e7f197-7df5-4ffd-ab80-e033bfe823bd	1.000
aabbe5fd-d92b-47f6-91ec-b7f0b95b417d	80be8cd4-9d9a-423b-970d-0f7d138c779b	9c44e792-4724-46eb-a278-875e6ce514a8	1.000
ab1d73d5-baa0-443b-bc2d-7e3f598f70c9	8ce39ccb-16c7-4aba-8b93-899cd3bff4fa	21c0a4c6-64c9-4223-a0c3-fee4ef7ebd1f	1.000
df422934-6cc1-49f4-a4fd-2a5905393403	b7299606-d51a-490f-8360-ead14cd488f6	6a7dc7ed-7a51-4954-9d06-68b9bd08d74c	1.000
7677e3a9-9c9a-4fb0-aee4-640615205e37	a8947a20-8f0a-419f-87c3-b4ece1515cd1	6860e5c8-8643-46d2-a6e9-bfe6e9fc80a0	1.000
97371e4e-7129-4615-a932-5a9d4b961bcc	fac8d34f-d617-4742-b911-9b16b952df69	8ca7f94b-d3d9-4a5e-860b-6a500b0d3502	1.000
8fe4c580-e22c-40d2-a383-ff569221f774	204cd496-4aba-44d0-b3a1-919bb4386000	edba16c2-09c9-47b2-977e-82d92a6b0582	1.000
39b11cad-593e-437d-8df7-65b1c74a494c	69a7d8cd-f428-4211-803a-11fea038e56e	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
81be6049-7eab-4549-9c9d-3fd3e0a7a4a6	5890cd36-f149-4667-9aa7-03375d3a31af	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
b6583e83-b501-4646-93e5-0d803b0e1274	1dcc3350-2fdb-4653-a60f-ec1212bb682e	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
5586d041-d451-40f6-8429-ea57e1d615d0	7e2e9acc-4cb0-4222-8e04-e09402820956	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
307ea2b4-3aa8-4ce6-aaaf-ef7a8ab2926b	fac18978-1efd-4b64-99a7-75758a3d73c6	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
b9a84c51-69bc-416f-add1-656de1b0debe	659bc0ec-f84d-4116-a67b-d586d5673641	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
a30180f7-0388-4b8e-85d7-78ba6efa8c3c	46a09e73-28f4-4df9-984a-95ac939cfe1a	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
30566687-ba43-4c65-ba87-9ecbc5c9d89e	3b9b5a6b-329f-4622-97ec-10226e8d5116	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
0a4d7bf6-3555-4f4c-9bfb-6293864f7b3b	4c60f063-cc76-4d22-a8ae-00001fdf4675	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
ec905685-0c3b-468e-8e96-6c16eb2b8cb9	e2028931-16ad-47cd-a58c-03359d67788d	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
64bf53b6-e7de-490d-a325-a1faef2d789e	19a0e1b1-b889-4cf6-b553-017f739929aa	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
60c2ac8e-dc84-4821-8a3f-8d8d1e5cecaf	e2551239-6d21-4a43-aac3-f435b261884e	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
0b766490-7bc0-4dce-a42e-d072b8ebc671	07ce2e45-1d07-45f3-8512-354a71348561	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
36f719ff-9c7f-4ca6-9e06-abcfed1c70f5	8a5290af-0957-4c14-a42b-88c6f7069761	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
27d780dd-50c6-4cb3-b4eb-610acf5ccb27	4f182459-6a5a-492e-8037-46ce31108923	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
fb35e318-583c-4c3c-bbc6-d377e2ae9fee	f7e925d5-6ce1-4a66-90d5-d48e28cec819	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
1bdfc6bf-3000-4269-88aa-e7d4d304e6a8	294aaf86-b061-4edb-9d76-83f43e34ca46	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
8f547670-0e05-4c59-b68d-5e3b3f862192	485b3d43-e043-4221-bb72-80d9a5095767	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
7d254c13-cb48-4185-a8fd-d3f59a2b2599	fae9bc78-c632-44ec-a196-9e9f7f970fa0	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
56f5f7aa-3eec-441e-8b1f-b18f203ce040	61a1aced-7d78-4d7d-9782-557a2e6622ec	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
e92ec7f4-465a-48a6-9ce3-40db2ebace61	dbf93f42-7b4c-4c7e-a873-10f18a2151b0	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
e377720a-08c5-4e7a-b45c-3b1c76d814f0	d74871da-b9f7-4a56-9a8a-9519599bf1be	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
a2dc0f27-43fc-4f83-b295-6cf46a02a78b	de76dbf1-aaab-4bac-9278-2e420f6eeaf3	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
61da96f7-9cac-4f47-a4dd-9ff97377d344	3acf88aa-9368-4a0b-a967-3e79d26c59dc	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
ea72b446-3e5c-4e34-b284-7460811d7032	0c8c099a-1d4b-4c78-be70-a2f846f9ce63	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
735c338e-b68c-4abb-b052-d25055b4eabe	934dde37-9033-45e6-86ed-7cdd2215b18e	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
4e639daf-c0b0-4c60-9e0d-8d928cf359dd	f2ceb9f5-5bbe-4b7d-8f8d-87fa4e9cc0db	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
94743440-f3f0-47ec-9535-b369644a7ff7	5a718736-9643-4ae4-824e-1c05f6d093dd	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
93757ddd-9102-4818-9dee-12c2274bdc1e	fbb74d1d-e719-4478-b4fb-df4a903e41d5	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
f8460357-d162-4c30-85f3-995f85d7ae48	78a775c5-9a24-4760-a370-483ebc35cd3d	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
119c769c-4fb4-4224-86fd-fe470b0f4b9b	e187c501-7b39-497d-95d8-832d0aa0ac66	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
3b3e783c-b802-4a4f-b1cf-0a1cefd87973	17f3e970-a0fa-4fac-8a67-e727f9b6e1e5	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
043ea383-e9ff-4533-a946-4307fe532101	f94e741c-9149-45e1-bdef-6e528dd57040	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
be028e65-da5c-48d7-9013-a705fcbc4fba	9789ad02-8eb7-46f3-8ce5-cf30a399add6	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
7e9c4024-d298-4e5b-92e4-06b4a71559ef	ff490dae-af6c-44b1-b8b7-71db1607bd67	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
7252db54-208a-4ff5-b710-85b904d7296d	f1e3cc01-c0cd-4013-b667-504db4e7e954	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
ee954fcb-737b-4959-b327-f7aef58eb55b	07f0b52a-05a5-4410-ad92-6c1b643c6110	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
ad8c4e5a-25a1-4c33-864b-37778f01d026	74da32a1-1f86-422a-afcf-f431b9765c75	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
c85c3762-3988-4d64-a6ca-b1348aee8706	da7a9d7b-64d7-46e9-9a66-fb411d1976e5	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
4d76c6f0-3088-4c3f-849b-ff99d4a8acf6	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
44d37a09-27b8-41ac-aa59-e7059bc0af46	6b36979a-fbea-4843-a832-85e8509a7d90	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
0080244a-09f8-459f-8ff3-518b274e6ed8	8bca5777-8762-40d2-a2f4-7c437a106df1	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
2212cb0d-92d5-49f2-aedf-0011acd3b044	4160714b-10ca-4c4f-8b8a-d4c2cba53724	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
3f81ae6e-a3c1-4c32-af5e-5bcd1d173bff	54e23930-a575-4bef-b0d1-7b8584a0b011	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
f3a457dd-11ca-4dba-ba63-bc6bb76409b8	355d16bb-9d61-4ed9-991e-66e0cae3d29e	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
18e7a1f0-9922-4181-85fd-7fac67692f39	eef3b439-112e-485e-a7b6-0d7cd40198bf	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
71b9add7-ab96-42ef-8a07-5b3aadaf51bf	ba286914-b27e-4b33-980d-9e768e8b6569	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
5598e25e-0ff2-4d64-a760-156f7292f1f9	836aa0a0-092c-4a2c-9982-7a2f5deb4880	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
d2517863-0106-480f-a7b6-ee9a3b12c692	ad312dc8-07cc-4429-ab36-054466502320	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
f25d6009-4cbf-479d-b30e-e287892f1aa9	5a1e5f5e-1d22-41f4-a3d1-cfec49e83974	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
ca976a7d-621e-4a88-ab3e-7d1a282c8608	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
08f95c4c-aa99-4308-ba26-0fe7f4df54ad	6417f382-7e3a-4884-a852-bc06176f6848	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
278996d9-3a12-4b1a-9565-aeae92363200	3cc363fc-99c1-4779-806b-e6d10019e507	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
efb84558-ddb2-47d6-8c8a-4ba00a7ad0a9	d725ab54-f42b-41c9-9da6-fd327076f301	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
c0aa3884-342c-4dc1-9d05-1314c104a929	59a3f6b4-9692-439f-ba35-8c9211bbff90	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
3de86d43-7ecd-457b-a41c-27aff78be3f6	c151009a-e385-4f46-a31b-6e1d536c093c	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
56d680b7-6124-4cfd-af49-189ae804bebe	d198ad03-c605-4e0b-a84b-dacac22eac4e	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
8ee86566-7075-45e6-92bb-5763805b5562	0c4413d8-507b-4f42-a29f-5b87d1c6d4eb	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
2a2c0477-fc64-446d-b9d0-d12b682b754c	03f09170-0f20-493b-afb8-5082ee95b407	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
741c4743-10bc-4b83-b369-b6d0d97a8bf0	18da79f3-6d8c-4f4c-a025-53b6d1bd36c0	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
6a56b4fe-1df8-45e5-8786-eb1d793d88dc	30179ad5-5045-4cf3-a666-9da609d74519	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
f61ea344-6806-4f30-a673-00aa6181e01e	3711b33e-f1bf-4416-91ea-5a85e467fe7b	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
e1ecf192-ad58-4172-b9c8-8126138fbf9a	176b9a0f-e557-43fa-8d36-5b111810a5e2	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
be030fa5-2ed6-4ce0-88a0-d0ad054f2262	17f0a5d7-b947-44af-8d36-5d17846b8fe8	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
b8eb01e2-c381-4f25-ad4a-ed2bdf0e9038	d1e25ad6-24a2-49c6-a9a0-ba42e55caa59	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
1e28876c-fb95-4287-bb23-1aeeb5ca24ff	48028a40-bf68-4e9b-a730-8b1aaac57cc2	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
9b0c397e-fa73-4ab6-90fe-9d05b98a87e0	6b0fb042-32f2-49f5-980a-85f6fae8bae4	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
ceed88bc-1d28-4195-b7e7-f2fefc8012ab	9aa4fbc0-8453-4000-9a0c-722fd3b0e285	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
fc793652-3982-4c83-bd38-41fefa7d316a	5320f791-91f4-4d1d-9c34-c548579ce7d4	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
0a9120ca-2ac8-45c7-97d1-8b35728deade	93d818db-0e5e-44a6-913b-379b64d489ae	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
a115874e-2b57-44b9-a403-ff6f729cd7fa	6a581cd8-87d4-47f5-9589-ad5d45634fb3	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
77c19466-02ce-4d58-aa9e-284bde6f4f03	fd3df342-68dd-4034-840a-98ce31f9c9b9	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
5b6b04b2-78de-4de9-9659-344d4b339074	fd86fafa-5bc2-4e8e-8c1c-99f3d1d3bc62	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
185ddbff-6438-43e2-8f73-0b7234746102	0ae6808c-7e1e-49f0-856a-ebfe2232965b	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
8b537e3e-882e-4fa6-a146-7ffc38e436da	4b89591b-e945-4e94-a7c9-8d1aa2d1c7ca	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
4c0763fe-02ee-4345-9f22-41050dcdd902	8b637a4c-48a2-4b14-b5c5-e233a972a424	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
f2a5377a-0721-47bf-985d-b7406806afe9	574e5b14-a2df-47a2-96e1-d48eecbc82a7	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
c02eaf39-3731-4010-9552-1d21507ba098	44888ce3-3f92-46b1-8fd1-1ffe6c925938	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
ac465bd1-db03-49d9-9a58-e3ed14940b83	b61d7f7b-66b0-4365-9ba9-07b046e06a06	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
91c6a830-7ffd-4db9-a3c4-4c3443c0c008	578fbb1b-8dea-4372-919e-464656bcc8e4	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
679be977-32e1-4923-b186-440a423563af	c0fd4f28-d8a7-45db-9637-1ad10947cba0	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
7466f1c3-80a6-4cce-bb4a-10b2a85befcf	6bf08757-24e5-4f49-8c97-1d3ff4ce8445	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
6a24f4c7-8a65-4bba-a902-1f369441ed8b	ff312382-ff3c-4870-a9cc-a0d94858cf22	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
ed394aec-670a-4bf8-bddf-8afb4dc6394a	5909c2e0-82a6-411f-bf64-f750508d3e15	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
92c65053-73c7-4440-a274-701d387347ce	eab3cf4c-79d6-462d-af6e-27f334337e7a	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
0567c84f-4754-40c5-95d8-a740d32fcb81	36140fcb-5a02-4e11-87ea-2244e7f02f00	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
a606049e-567c-4fd4-8798-7f381ed2dcae	e8200d8e-fe2d-4773-90e0-4dfb57095ba9	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
9909cb49-2c0b-4b18-91bd-124029927f72	06698559-0c78-4538-a68a-f9fc073f8ee7	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
3c44a9cb-4184-451f-b1af-ff713d345401	3b88851d-6135-478b-ae23-72cdc60db21c	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
3bc91b7b-6041-4778-a325-ad5d6c6e6b69	dbbddcfa-2700-4728-9493-265036c0f5f6	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
0d6f4b2a-0df3-4ae4-8a46-c4fd645c1174	97683af9-8deb-4bfe-8a69-c115b265d9de	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
9dc4cee3-c6c2-47ba-b0a0-0391ff356894	988afbd3-9eb1-4d81-afcd-3458e0ffeea6	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
d1239284-99a0-48f7-bb7a-0964a61db652	c8c7ab09-63fd-4d61-ba67-9120765d4b2b	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
2a73bdc0-9a19-42e9-8380-6e8e04151b8e	ac9c133e-81d1-4eff-8f91-489e140066dc	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
6c3bebce-f277-4fb0-b2fe-c65e6df99385	17287969-3735-43a8-930f-7b82994167e8	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
a0b88d1e-6a52-4cd2-9787-cf8b2961ca93	c26c8bca-782e-40ab-bc15-ed42ea1de1aa	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
fa8224f2-5dfa-416d-b751-aa83d4d6c4ac	7daa6be8-3b60-452f-8488-cd7f5a44b3ae	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
a4a87e6f-3621-4154-8560-0666aaa942b6	28335d4b-c36a-4774-9cab-553727dc88ee	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
478a7a6a-9fd1-466b-8ae2-60bc94b6ae45	239a4bae-bea4-40e5-98bd-85dfafa0ab4d	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
86e3ef35-7797-4941-94a2-0ab44b056e01	38b3b46c-98fd-4600-ae3d-6d860fa5eaed	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
56adece6-d2ba-4651-b494-ad89973a901d	ff82580c-7f61-43fc-a317-6e5bcbeca719	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
c3659403-a62d-4d0b-bdf0-1f5472d72262	e660378e-5bd1-45cb-9471-eba8487e218c	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
2216f939-2ff6-4cd4-9535-c6c86082def7	0ea96d01-3bae-49d9-a310-a8134c4c1c67	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
29ea9c8a-c718-40c2-a616-e4e68a23c6ed	0f384836-61aa-41f0-9eca-f21c89c3ae9a	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
5051d6b0-88e7-4d41-81e4-54404f6ab868	a04b9537-8885-45f0-9619-c4df6d38cff9	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
34d36652-653d-4e31-82d8-5b7550a0bf5c	df2a62c3-58d6-430f-b10e-45b0cb58cff1	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
6edad8be-faf2-469a-bb7c-1c7d35121321	1ccc930c-4c9b-4e72-a8b9-da1012c9a30f	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
27394642-209b-470f-b62d-fdac7b60411f	6c2bde92-5e59-4471-a9f0-4c3518bfc525	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
eaec63fe-dbce-4edc-9fe6-8e89244b517e	93b1f693-b2ca-4ca6-8abd-bbd9abcfd971	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
aa8c7ce5-e8b8-49a9-a25b-5c75835f45b6	821840ca-5fb1-4524-8e46-cff9e1f2813b	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.286
51491a23-2a3e-4f83-8710-a0738d066dcc	9730e484-0913-497b-8663-b228822b3ddc	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
5912f06b-ba40-4cd8-99c6-4154017455cf	9011c9d2-8ebf-495d-b21f-bf0078edf101	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
da3620c9-f530-4c65-89d3-8f889db57515	a5a48573-591b-4c2a-8309-14d0046cdbe9	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
e305e8b6-fb20-427a-b3e2-c69cb76fe338	af3be04d-99fb-4841-96be-dc328bcafbf4	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
958e3c3d-a768-4eff-98b8-135b8e432403	22ce35b9-eb8e-4266-9efd-1df179928fe7	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
346159bd-22ec-47d2-a7eb-0e4ec0b6e2c9	89d222ed-0310-4f2b-8f99-c4a23f6ae217	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
0a7c7aa3-d2ce-4154-a623-b1154b165e69	e8b15a64-4e2d-421b-bddf-9c5a7601029a	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
803ef4ba-d39d-46b3-90b1-bd2a4cfa9809	9e22a47d-c54b-444a-8bcc-76a86bdf420c	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
45353ffd-f819-40c9-b8e4-f5546065f4f7	16a4a62f-bcfd-435d-b061-3dfb4b8d4bd5	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
98d6f20a-4a98-4015-ba0e-39753142d18f	5e0c5771-60b0-4f71-8e5e-087e30a7e179	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
9bef70dd-6a01-48d5-97fd-af74b923aa22	643f4827-4ce5-47b4-8823-5bd1d606e982	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
dbbf03b9-520d-46bc-b905-cfd8e487903a	ce629d3f-73b4-4bc1-aa6a-2ccb49044366	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
d44a39aa-1a02-4616-b9c5-191f42ed1973	2583530a-529b-42b0-987a-1db7b96d24fd	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
c7889264-f3e5-40e0-859d-16c58c6ab0c6	708a41d7-0323-42ee-8725-a3ab898bd39d	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
63802d94-3c58-4cd6-b03e-a328d5fa25a6	4f4a6067-f359-4422-bbbb-20f5aaded6b3	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
c620ff9d-fe99-4e4d-a5d9-0c7408569669	b5fde150-980d-4922-82aa-71a971fbdc11	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
02428d8b-44ff-4ff6-8e9e-36e11e8c4ab8	e328a67e-40df-4b18-903d-a5938ad83d56	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
ce30f42c-9982-4ea7-ab4a-8b5c3f5c1306	b6337c04-bc7e-4f77-ae64-4fd7e717784b	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
5438fb10-3dbf-4ecc-b4d3-96802923193a	37ac1c8b-58e7-4508-857d-d684763c2a05	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
165604b5-7520-4236-81ce-5585c73333ce	93418cf7-cec2-4441-925a-2917ba67479a	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
76cb1c6a-9ffa-4676-8991-dbf11d8f08b1	4fa1d747-7bc0-4ec1-b54e-371169717ec3	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
c67fdc7f-83b0-4c11-8e61-7bc474d8ce3c	f8c3551b-ce83-449e-a6c1-a640f89e8e68	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
9a106717-0a0b-407b-97db-f65da8014c4c	f01823cb-78e6-4174-9d72-aadfd2436a19	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
fd7b406e-ea32-4c5c-a1be-c905e68385de	0ef25e78-4f76-4d3c-bbe5-3ae6afcb1c77	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
c0094b9e-935e-48d5-8129-d5076be74e9c	ba1fbd68-73d4-4610-8b06-bf2bbb4ca927	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
8a7e447f-ccee-482e-a030-11e5070cceec	90ad3b70-6c4f-4050-a3c5-d157cd072af5	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
536d9a4c-bfdb-456c-abc7-cfaa2bd7a938	d1ca497d-4d17-4b6f-b7a5-37d772e72507	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
abf5e4df-a55f-4d12-bc80-1f340272d5d1	91355c62-fd26-494e-9c6c-910d5837a22a	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
dcb3eaa2-5720-4c15-9b59-3f0e10a468d7	edc21662-09f3-4f30-acb3-714a69cac870	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
7372878a-94ba-47b2-b946-47bb42b3e9d4	ee109fb4-61db-4bd2-803d-911a26183e28	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
f2fa3589-26b3-4673-9f03-5e1849761561	243e0846-82f3-47e2-8e25-77e32ec08ef3	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
aa48a4a1-8f1c-4e44-9adf-7cde4ea6957d	ffaae71c-9438-4299-8493-21ce4201f095	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
134bb401-59ea-454e-9e78-1a50174a052a	28e30eaa-c921-4371-8e7e-f0c7d3d1e011	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
b5dc9a2e-e150-4e50-a579-da9687e42823	b9aac2ad-498b-4996-85ab-4a87a3bf8b93	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
2b6da9d7-f56b-44da-a46e-4b2d99f1d782	d354b5f0-e3a9-4024-9a11-6524de50706c	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
0bb45a4d-ab6f-4386-b317-695ad1358bb9	c227722f-b1c2-4c4b-b00a-33424082f995	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
c05fb7f8-5bc9-4690-80d4-fa0776b55d62	4aa4a646-b2c9-4ac8-8253-71a9b459eaec	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
77e48d75-48f0-4b66-814d-c2341b317cee	e124aaf5-e8c4-4540-a893-6c1bda0142e1	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
4cbafcc0-d1dd-4087-9c8d-848f8ce70fb1	2df7ac91-2836-49ed-ace0-40ca1cb82fc0	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
6ddb8e92-e62f-4524-9971-c63f2e6e4e36	22956d43-3013-43b2-a1ce-0480e9abec6a	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
b93b7ac9-d0fc-4170-bdce-18b708bab78f	ab541db9-d472-4db5-b3aa-ffc75fb46468	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
16624cc8-8bc5-47e0-a281-6eda3efb591c	1670d48a-5aa8-484b-8d51-87c0552f423d	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
51ccf7d7-3c87-4555-a13a-5df73c50511f	89acb320-982c-45ac-8675-16e846d5dcf7	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
3c915789-d792-4b98-b649-2343223f9995	5617cdc0-98fd-4866-a33b-9571696ab1e5	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
f704d76f-9c3e-4d2e-909b-b75dbc40a6d8	2c470520-ac57-4c94-bc51-2e952fe1ab21	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
8e969762-d32b-4370-8ca7-15ea601b00e7	ab821a9a-4978-4b9e-ad54-672a6e3d99fc	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
d0c9b9a4-5871-488f-ad44-e1d809b01da1	f961c0e4-5a4b-4655-9e63-d8a9f273b5ea	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
7a8ea4fd-fd5e-48b1-85cf-45a24a699362	cd408593-401c-46d0-8507-624f0342f05a	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
fd44820b-35d4-4617-abfe-872bf8e8c333	e107e808-3fe7-4ec8-b425-00b515a6abe5	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
1e15ab77-88e0-4d31-9493-5c026774ea92	b7acc96a-f4f3-4722-b388-91a0d82cdfff	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
\.


--
-- Data for Name: product_price_history; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.product_price_history (id, product_id, old_price_xof, new_price_xof, changed_by_user_id, changed_at, reason, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.products (id, category_id, name, short_name, price_xof, vat_rate, track_stock, is_custom, is_active, sort_order, color, sku, created_at, updated_at) FROM stdin;
ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Sosso	Salade Pan. + Sosso	4000	0.00	f	f	t	3	cyan	SYL-034	2026-10-06 10:44:50.780116+00	2026-10-06 10:44:50.780123+00
4fa1d747-7bc0-4ec1-b54e-371169717ec3	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Poisson braisé	Salade Pan.+Pois.Bra	5000	0.00	f	f	t	4	cyan	SYL-035	2026-10-06 10:44:50.783593+00	2026-10-06 10:44:50.783601+00
f8c3551b-ce83-449e-a6c1-a640f89e8e68	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Kope + Poisson	Kab.Kope + Poisson	3000	0.00	f	f	t	10	ambre	SYL-010	2026-10-06 10:44:50.681216+00	2026-10-06 10:44:50.681223+00
f01823cb-78e6-4174-9d72-aadfd2436a19	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Lafri + Poisson	Kab.Lafri + Poisson	3000	0.00	f	f	t	12	ambre	SYL-012	2026-10-06 10:44:50.689856+00	2026-10-06 10:44:50.689865+00
5a718736-9643-4ae4-824e-1c05f6d093dd	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Kope + Mouton	Kabato Kope + Mouton	3500	0.00	f	f	t	13	ambre	SYL-013	2026-10-06 10:44:50.693912+00	2026-10-06 10:44:50.693921+00
e187c501-7b39-497d-95d8-832d0aa0ac66	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Lafri + Mouton	Kab.Lafri + Mouton	3500	0.00	f	f	t	15	ambre	SYL-015	2026-10-06 10:44:50.702328+00	2026-10-06 10:44:50.70234+00
0ef25e78-4f76-4d3c-bbe5-3ae6afcb1c77	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Feuille + Poisson	Sce Feuille+Poisson	3000	0.00	f	f	t	3	vert	SYL-018	2026-10-06 10:44:50.715717+00	2026-10-06 10:44:50.715723+00
355d16bb-9d61-4ed9-991e-66e0cae3d29e	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Feuille + Mouton	Sce Feuille + Mouton	3500	0.00	f	f	t	4	vert	SYL-019	2026-10-06 10:44:50.719063+00	2026-10-06 10:44:50.71907+00
ba1fbd68-73d4-4610-8b06-bf2bbb4ca927	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Dah + Poisson	Sauce Dah + Poisson	3000	0.00	f	f	t	7	vert	SYL-022	2026-10-06 10:44:50.730212+00	2026-10-06 10:44:50.73022+00
8bca5777-8762-40d2-a2f4-7c437a106df1	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Dah + Mouton	Sauce Dah + Mouton	3500	0.00	f	f	t	8	vert	SYL-023	2026-10-06 10:44:50.734022+00	2026-10-06 10:44:50.734031+00
90ad3b70-6c4f-4050-a3c5-d157cd072af5	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Légume + Poisson	Sce Légume + Poisson	3000	0.00	f	f	t	11	vert	SYL-026	2026-10-06 10:44:50.745084+00	2026-10-06 10:44:50.745094+00
836aa0a0-092c-4a2c-9982-7a2f5deb4880	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Légume + Mouton	Sce Légume + Mouton	3500	0.00	f	f	t	12	vert	SYL-027	2026-10-06 10:44:50.748992+00	2026-10-06 10:44:50.748999+00
d1ca497d-4d17-4b6f-b7a5-37d772e72507	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Poisson	Tchep + Poisson	3000	0.00	f	f	t	3	rouge	SYL-039	2026-10-06 10:44:50.799518+00	2026-10-06 10:44:50.799525+00
91355c62-fd26-494e-9c6c-910d5837a22a	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Poisson	Yassa + Poisson	3000	0.00	f	f	t	7	rouge	SYL-043	2026-10-06 10:44:50.815943+00	2026-10-06 10:44:50.815951+00
d725ab54-f42b-41c9-9da6-fd327076f301	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Mouton	Yassa + Mouton	3500	0.00	f	f	t	8	rouge	SYL-044	2026-10-06 10:44:50.821825+00	2026-10-06 10:44:50.821835+00
fae9bc78-c632-44ec-a196-9e9f7f970fa0	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname bouillie + Sosso	Ign.Bouillie + Sosso	4000	0.00	f	f	t	3	brun	SYL-047	2026-10-06 10:44:50.836805+00	2026-10-06 10:44:50.836813+00
edc21662-09f3-4f30-acb3-714a69cac870	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname bouillie + Poisson braisé	Ign.Bouillie+Pois.Br	5000	0.00	f	f	t	4	brun	SYL-048	2026-10-06 10:44:50.840774+00	2026-10-06 10:44:50.840781+00
294aaf86-b061-4edb-9d76-83f43e34ca46	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname bouillie + Mouton	Ign.Bouillie+Mouton	3500	0.00	f	f	t	5	brun	SYL-049	2026-10-06 10:44:50.844541+00	2026-10-06 10:44:50.84455+00
de76dbf1-aaab-4bac-9278-2e420f6eeaf3	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname frite + Sosso	Igname frite + Sosso	4000	0.00	f	f	t	8	brun	SYL-052	2026-10-06 10:44:50.855472+00	2026-10-06 10:44:50.855479+00
ee109fb4-61db-4bd2-803d-911a26183e28	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname frite + Poisson braisé	Ign.Frite+Pois.Brais	5000	0.00	f	f	t	9	brun	SYL-053	2026-10-06 10:44:50.858898+00	2026-10-06 10:44:50.858905+00
dbf93f42-7b4c-4c7e-a873-10f18a2151b0	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname frite + Mouton	Ign.Frite + Mouton	3500	0.00	f	f	t	10	brun	SYL-054	2026-10-06 10:44:50.862652+00	2026-10-06 10:44:50.862658+00
4f182459-6a5a-492e-8037-46ce31108923	8f3be9d2-6b4b-4c36-8970-b87c90101139	Frites + Sosso	Frites + Sosso	4000	0.00	f	f	t	13	brun	SYL-057	2026-10-06 10:44:50.872843+00	2026-10-06 10:44:50.872852+00
243e0846-82f3-47e2-8e25-77e32ec08ef3	8f3be9d2-6b4b-4c36-8970-b87c90101139	Frites + Poisson braisé	Frites + Pois.Braisé	5000	0.00	f	f	t	14	brun	SYL-058	2026-10-06 10:44:50.876573+00	2026-10-06 10:44:50.87658+00
07ce2e45-1d07-45f3-8512-354a71348561	8f3be9d2-6b4b-4c36-8970-b87c90101139	Frites + Mouton	Frites + Mouton	3500	0.00	f	f	t	15	brun	SYL-059	2026-10-06 10:44:50.880499+00	2026-10-06 10:44:50.880507+00
3b9b5a6b-329f-4622-97ec-10226e8d5116	8f3be9d2-6b4b-4c36-8970-b87c90101139	Attiéké + Sosso	Attiéké + Sosso	4000	0.00	f	f	t	18	brun	SYL-062	2026-10-06 10:44:50.890769+00	2026-10-06 10:44:50.890776+00
ffaae71c-9438-4299-8493-21ce4201f095	8f3be9d2-6b4b-4c36-8970-b87c90101139	Attiéké + Poisson braisé	Attiéké+Pois.Braisé	5000	0.00	f	f	t	19	brun	SYL-063	2026-10-06 10:44:50.895342+00	2026-10-06 10:44:50.895352+00
659bc0ec-f84d-4116-a67b-d586d5673641	8f3be9d2-6b4b-4c36-8970-b87c90101139	Attiéké + Mouton	Attiéké + Mouton	3500	0.00	f	f	t	20	brun	SYL-064	2026-10-06 10:44:50.899153+00	2026-10-06 10:44:50.899161+00
7e2e9acc-4cb0-4222-8e04-e09402820956	8f3be9d2-6b4b-4c36-8970-b87c90101139	Alloco + Sosso	Alloco + Sosso	4000	0.00	f	f	t	23	brun	SYL-067	2026-10-06 10:44:50.909708+00	2026-10-06 10:44:50.909716+00
28e30eaa-c921-4371-8e7e-f0c7d3d1e011	8f3be9d2-6b4b-4c36-8970-b87c90101139	Alloco + Poisson braisé	Alloco + Pois.Braisé	5000	0.00	f	f	t	24	brun	SYL-068	2026-10-06 10:44:50.913413+00	2026-10-06 10:44:50.913422+00
5890cd36-f149-4667-9aa7-03375d3a31af	8f3be9d2-6b4b-4c36-8970-b87c90101139	Alloco + Mouton	Alloco + Mouton	3500	0.00	f	f	t	25	brun	SYL-069	2026-10-06 10:44:50.916907+00	2026-10-06 10:44:50.916915+00
f94e741c-9149-45e1-bdef-6e528dd57040	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Boeuf	Petit pois + Boeuf	3000	0.00	f	f	t	27	brun	SYL-071	2026-10-06 10:44:50.924133+00	2026-10-06 10:44:50.924141+00
ff490dae-af6c-44b1-b8b7-71db1607bd67	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Poulet	Petit pois + Poulet	3000	0.00	f	f	t	28	brun	SYL-072	2026-10-06 10:44:50.928059+00	2026-10-06 10:44:50.928068+00
f1e3cc01-c0cd-4013-b667-504db4e7e954	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Sosso	Petit pois + Sosso	4500	0.00	f	f	t	29	brun	SYL-073	2026-10-06 10:44:50.931498+00	2026-10-06 10:44:50.931507+00
b9aac2ad-498b-4996-85ab-4a87a3bf8b93	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Poisson braisé	P.Pois + Pois.Braisé	5500	0.00	f	f	t	30	brun	SYL-074	2026-10-06 10:44:50.935492+00	2026-10-06 10:44:50.935501+00
b8747001-a8c8-4cc8-b623-b7ea096ff33d	39443ae1-ee99-4f2e-a739-5f60cafbc6fe	Lait	Lait	1000	0.00	f	f	t	1	rose	SYL-075	2026-10-06 10:44:50.942969+00	2026-10-06 10:44:50.942977+00
c39717d7-bb67-4780-9bbe-47a00cc2f12b	39443ae1-ee99-4f2e-a739-5f60cafbc6fe	Dégué	Dégué	1000	0.00	f	f	t	2	rose	SYL-076	2026-10-06 10:44:50.945155+00	2026-10-06 10:44:50.945163+00
8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	39443ae1-ee99-4f2e-a739-5f60cafbc6fe	Salade de fruits	Salade de fruits	500	0.00	f	f	t	3	rose	SYL-077	2026-10-06 10:44:50.948565+00	2026-10-06 10:44:50.948572+00
26eb12b5-a751-40b0-a6a2-6935fe010159	74b13cc9-1d3b-41d7-80c4-88573b1e7812	Tamarin	Tamarin	500	0.00	t	f	t	3	bleu	SYL-080	2026-10-06 10:44:50.961688+00	2026-10-06 11:17:16.911483+00
6d9aee30-24bf-4df9-a616-ada6c53c4043	74b13cc9-1d3b-41d7-80c4-88573b1e7812	Bissap	Bissap	500	0.00	t	f	t	2	bleu	SYL-079	2026-10-06 10:44:50.957595+00	2026-10-06 11:17:16.911492+00
cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	74b13cc9-1d3b-41d7-80c4-88573b1e7812	Passion	Passion	1000	0.00	t	f	t	1	bleu	SYL-078	2026-10-06 10:44:50.955601+00	2026-10-06 11:17:16.911495+00
d06c79a2-0485-4ee2-bfc4-10d740c69241	49ce3191-0c59-453e-ba4f-921458c9629c	Plat mouton	Plat mouton	4000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.754253+00	2026-10-20 15:03:07.75426+00
120dc3c0-0932-4219-94d7-01f56c5e1139	49ce3191-0c59-453e-ba4f-921458c9629c	Plat bœuf	Plat boeuf	3000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.754266+00	2026-10-20 15:03:07.754268+00
11d8e671-0244-4066-854d-eede1fb90a58	49ce3191-0c59-453e-ba4f-921458c9629c	Plat poulet	Plat poulet	3000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.754274+00	2026-10-20 15:03:07.754276+00
f0dd6e5d-fc7f-4518-b2a4-731ef5de1bec	49ce3191-0c59-453e-ba4f-921458c9629c	Kedjenou	Kedjenou	3000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.75428+00	2026-10-20 15:03:07.754282+00
601cc27a-9aad-4b65-935b-ec59b39a2e5b	37f33917-e947-438e-a046-1530d7dced56	Plat faux brochet	Plat faux brochet	3500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808461+00	2026-10-20 15:03:07.808468+00
f2ed4eac-2031-4814-af66-619be36324f0	37f33917-e947-438e-a046-1530d7dced56	Sosso 3000	Sosso 3000	3000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808475+00	2026-10-20 15:03:07.808477+00
e0648d5b-df64-444f-82cf-0d18b472b3db	37f33917-e947-438e-a046-1530d7dced56	Sosso 3500	Sosso 3500	3500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808483+00	2026-10-20 15:03:07.808485+00
9e31b16b-aac4-4431-9012-60dcc2e4e0d9	37f33917-e947-438e-a046-1530d7dced56	Sosso 4000	Sosso 4000	4000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.80849+00	2026-10-20 15:03:07.808492+00
23c6c6ec-ad5a-4626-8bfb-0076cf03534d	37f33917-e947-438e-a046-1530d7dced56	Sosso 4500	Sosso 4500	4500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808499+00	2026-10-20 15:03:07.808501+00
4f84df00-4f47-4ba8-b119-ea5e01d7d16c	37f33917-e947-438e-a046-1530d7dced56	Sosso 5000	Sosso 5000	5000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808505+00	2026-10-20 15:03:07.808507+00
c6ba2d3b-c3bd-42ba-b0d2-9adf3e1ad10f	37f33917-e947-438e-a046-1530d7dced56	Sosso 5500	Sosso 5500	5500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808512+00	2026-10-20 15:03:07.808514+00
53dbcb50-bebb-4593-9e98-27e713d3da4d	37f33917-e947-438e-a046-1530d7dced56	Faux saumon	Faux saumon	3000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808519+00	2026-10-20 15:03:07.808521+00
5839313f-ebfa-478e-b99c-b79a1b75b313	37f33917-e947-438e-a046-1530d7dced56	Carpe 4000	Carpe 4000	4000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808526+00	2026-10-20 15:03:07.808528+00
6b776576-c91e-4151-b22b-d05e320b2f30	37f33917-e947-438e-a046-1530d7dced56	Carpe 5000	Carpe 5000	5000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808533+00	2026-10-20 15:03:07.808535+00
da028acf-3dee-46cb-a28d-60a205795865	37f33917-e947-438e-a046-1530d7dced56	Loss 3000	Loss 3000	3000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808539+00	2026-10-20 15:03:07.808541+00
882bccb2-37b1-4ce0-ae49-976744d001de	37f33917-e947-438e-a046-1530d7dced56	Loss 3500	Loss 3500	3500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808546+00	2026-10-20 15:03:07.808548+00
9d0f0b4f-a32e-42f5-b23d-692d756cb566	37f33917-e947-438e-a046-1530d7dced56	Loss 4000	Loss 4000	4000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.808552+00	2026-10-20 15:03:07.808554+00
c56c3a9c-5317-4e3e-be7b-1bed326fe53f	8c3313e1-5e72-4262-9eed-79fb512a9661	Foufou/foutou mouton	Foufou mouton	4000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.838637+00	2026-10-20 15:03:07.838644+00
ceafb668-7cd6-4c8f-90cd-f44a62dc5c26	8c3313e1-5e72-4262-9eed-79fb512a9661	Foufou/foutou bœuf	Foufou boeuf	3500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.83865+00	2026-10-20 15:03:07.838652+00
bfee22fc-f027-48c3-92af-f2f2f6e6145b	8c3313e1-5e72-4262-9eed-79fb512a9661	Foufou/foutou poulet	Foufou poulet	3500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.838656+00	2026-10-20 15:03:07.838658+00
01dbc122-a427-4ddb-ac94-6281b3301c7e	8c3313e1-5e72-4262-9eed-79fb512a9661	Foufou/foutou faux brochet	Foufou faux brochet	3500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.838661+00	2026-10-20 15:03:07.838663+00
5cfd2f16-4522-40b6-9108-71b863c98ebd	8c3313e1-5e72-4262-9eed-79fb512a9661	Complément foufou/foutou	Complement foufou	1000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.838667+00	2026-10-20 15:03:07.838669+00
07b7b353-3722-44dc-9e01-0a987fb8a909	725977b4-b95d-4b97-8979-c9b03b716e54	Alloco	Alloco	1000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.852775+00	2026-10-20 15:03:07.852784+00
50b3c6c2-f9c7-45f8-a36b-c027e5420b22	725977b4-b95d-4b97-8979-c9b03b716e54	Attiéké	Attieke	1000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.85279+00	2026-10-20 15:03:07.852791+00
6493d0b4-8184-4513-bf08-2ce645770216	725977b4-b95d-4b97-8979-c9b03b716e54	Igname	Igname	1000	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.852794+00	2026-10-20 15:03:07.852797+00
be1c321d-e8ad-4910-b02e-412d149b7595	14f64e21-345b-4e83-8013-84b96f36d717	Jus de gingembre	Jus gingembre	500	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.874218+00	2026-10-20 15:03:07.874224+00
5cbd0c22-be56-429e-b0ea-07e3dd917763	14f64e21-345b-4e83-8013-84b96f36d717	Jus de bissap	Jus bissap	500	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.874231+00	2026-10-20 15:03:07.874233+00
00fc07e5-eee4-4d2b-afe7-a965d7a8ebb8	14f64e21-345b-4e83-8013-84b96f36d717	Jus Tomy	Jus Tomy	500	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.874237+00	2026-10-20 15:03:07.874239+00
60621b43-1544-48ec-ac29-4b90c955c8da	14f64e21-345b-4e83-8013-84b96f36d717	Jus de citron	Jus citron	500	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.874242+00	2026-10-20 15:03:07.874244+00
c718be08-114b-480b-8367-75cb510147cd	14f64e21-345b-4e83-8013-84b96f36d717	Jus de passion	Jus passion	1000	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.874248+00	2026-10-20 15:03:07.87425+00
b809a15b-9263-4a5e-8412-a09959a2c846	b37e8530-2a55-4840-8d02-44dac8c38f9b	Sucrerie bouteille	Sucrerie bouteille	1000	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.894311+00	2026-10-20 15:03:07.894319+00
a90e5445-f9cc-489a-8add-b74b9730ac84	b37e8530-2a55-4840-8d02-44dac8c38f9b	Canette sucrerie	Canette sucrerie	500	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.894325+00	2026-10-20 15:03:07.894327+00
b09de5c7-8ea7-428e-ac90-6ae2d292dfff	b37e8530-2a55-4840-8d02-44dac8c38f9b	Canette Ivorio	Canette Ivorio	1000	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.894331+00	2026-10-20 15:03:07.894332+00
80be8cd4-9d9a-423b-970d-0f7d138c779b	b37e8530-2a55-4840-8d02-44dac8c38f9b	Orangina 50 cl	Orangina 50cl	1000	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.894337+00	2026-10-20 15:03:07.894338+00
8ce39ccb-16c7-4aba-8b93-899cd3bff4fa	b37e8530-2a55-4840-8d02-44dac8c38f9b	Canette Cody's	Canette Codys	1000	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.894342+00	2026-10-20 15:03:07.894344+00
b7299606-d51a-490f-8360-ead14cd488f6	7bd0dcc5-e575-459d-a8be-5e5aab739953	Eau Celeste 0,5 L	Eau 0,5L	500	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.905534+00	2026-10-20 15:03:07.905541+00
a8947a20-8f0a-419f-87c3-b4ece1515cd1	7bd0dcc5-e575-459d-a8be-5e5aab739953	Eau Celeste 1,5 L	Eau 1,5L	1000	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.905547+00	2026-10-20 15:03:07.905549+00
fac8d34f-d617-4742-b911-9b16b952df69	bc1e03a7-e276-4da7-8f57-34d6d901bdb7	Café expresso	Cafe expresso	500	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.91616+00	2026-10-20 15:03:07.916168+00
6cfeedc3-d8f0-4049-bf87-66bc59fc49d5	bc1e03a7-e276-4da7-8f57-34d6d901bdb7	Thé	The	500	0.00	f	f	t	0	\N	\N	2026-10-20 15:03:07.916173+00	2026-10-20 15:03:07.916175+00
204cd496-4aba-44d0-b3a1-919bb4386000	bc1e03a7-e276-4da7-8f57-34d6d901bdb7	Lait / dêguê	Lait degue	1000	0.00	t	f	t	0	\N	\N	2026-10-20 15:03:07.916179+00	2026-10-20 15:03:07.91618+00
07f0b52a-05a5-4410-ad92-6c1b643c6110	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Boeuf	Salade Pan. + Boeuf	3000	0.00	f	f	t	1	cyan	SYL-032	2026-10-06 10:44:50.773823+00	2026-10-23 11:43:19.653924+00
17f3e970-a0fa-4fac-8a67-e727f9b6e1e5	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Lafri + Poulet	Kab.Lafri + Poulet	3000	0.00	f	f	t	6	ambre	SYL-006	2026-10-06 10:44:50.665555+00	2026-10-23 11:43:19.653934+00
19a0e1b1-b889-4cf6-b553-017f739929aa	b8baea0e-44c7-46eb-807f-a553310c5f7c	Couscous + Poulet	Couscous + Poulet	3000	0.00	f	f	t	2	orange	SYL-029	2026-10-06 10:44:50.758375+00	2026-10-23 11:43:19.653937+00
1cff1a75-2cd4-4f08-b161-df8e796b4831	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Kope + Tripe	Kabato Kope + Tripe	3000	0.00	f	f	t	1	ambre	SYL-001	2026-10-06 10:44:50.64439+00	2026-10-23 11:43:19.65394+00
1dcc3350-2fdb-4653-a60f-ec1212bb682e	8f3be9d2-6b4b-4c36-8970-b87c90101139	Alloco + Poulet	Alloco + Poulet	3000	0.00	f	f	t	22	brun	SYL-066	2026-10-06 10:44:50.906012+00	2026-10-23 11:43:19.653943+00
3acf88aa-9368-4a0b-a967-3e79d26c59dc	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Dah + Boeuf	Kabato Dah + Boeuf	3000	0.00	f	f	t	8	ambre	SYL-008	2026-10-06 10:44:50.673705+00	2026-10-23 11:43:19.653945+00
3cc363fc-99c1-4779-806b-e6d10019e507	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Boeuf	Yassa + Boeuf	3000	0.00	f	f	t	5	rouge	SYL-041	2026-10-06 10:44:50.806323+00	2026-10-23 11:43:19.653948+00
4160714b-10ca-4c4f-8b8a-d4c2cba53724	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Dah + Poulet	Sauce Dah + Poulet	3000	0.00	f	f	t	6	vert	SYL-021	2026-10-06 10:44:50.726046+00	2026-10-23 11:43:19.65395+00
46a09e73-28f4-4df9-984a-95ac939cfe1a	8f3be9d2-6b4b-4c36-8970-b87c90101139	Attiéké + Poulet	Attiéké + Poulet	3000	0.00	f	f	t	17	brun	SYL-061	2026-10-06 10:44:50.887303+00	2026-10-23 11:43:19.653952+00
485b3d43-e043-4221-bb72-80d9a5095767	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname bouillie + Poulet	Ign.Bouillie+Poulet	3000	0.00	f	f	t	2	brun	SYL-046	2026-10-06 10:44:50.83299+00	2026-10-23 11:43:19.653955+00
4c60f063-cc76-4d22-a8ae-00001fdf4675	b8baea0e-44c7-46eb-807f-a553310c5f7c	Couscous + Boeuf	Couscous + Boeuf	3000	0.00	f	f	t	1	orange	SYL-028	2026-10-06 10:44:50.756288+00	2026-10-23 11:43:19.653957+00
54e23930-a575-4bef-b0d1-7b8584a0b011	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Feuille + Boeuf	Sce Feuille + Boeuf	3000	0.00	f	f	t	1	vert	SYL-016	2026-10-06 10:44:50.710123+00	2026-10-23 11:43:19.653959+00
59a3f6b4-9692-439f-ba35-8c9211bbff90	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Poulet	Yassa + Poulet	3000	0.00	f	f	t	6	rouge	SYL-042	2026-10-06 10:44:50.812365+00	2026-10-23 11:43:19.653962+00
5a1e5f5e-1d22-41f4-a3d1-cfec49e83974	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Boeuf	Tchep + Boeuf	3000	0.00	f	f	t	1	rouge	SYL-037	2026-10-06 10:44:50.794451+00	2026-10-23 11:43:19.653964+00
61a1aced-7d78-4d7d-9782-557a2e6622ec	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname frite + Boeuf	Igname frite + Boeuf	3000	0.00	f	f	t	6	brun	SYL-050	2026-10-06 10:44:50.847862+00	2026-10-23 11:43:19.653967+00
6417f382-7e3a-4884-a852-bc06176f6848	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Poulet	Tchep + Poulet	3000	0.00	f	f	t	2	rouge	SYL-038	2026-10-06 10:44:50.796351+00	2026-10-23 11:43:19.653969+00
69a7d8cd-f428-4211-803a-11fea038e56e	8f3be9d2-6b4b-4c36-8970-b87c90101139	Alloco + Boeuf	Alloco + Boeuf	3000	0.00	f	f	t	21	brun	SYL-065	2026-10-06 10:44:50.902485+00	2026-10-23 11:43:19.653971+00
6b36979a-fbea-4843-a832-85e8509a7d90	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Dah + Boeuf	Sauce Dah + Boeuf	3000	0.00	f	f	t	5	vert	SYL-020	2026-10-06 10:44:50.722512+00	2026-10-23 11:43:19.653974+00
78a775c5-9a24-4760-a370-483ebc35cd3d	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Lafri + Boeuf	Kabato Lafri + Boeuf	3000	0.00	f	f	t	9	ambre	SYL-009	2026-10-06 10:44:50.677353+00	2026-10-23 11:43:19.653976+00
8a5290af-0957-4c14-a42b-88c6f7069761	8f3be9d2-6b4b-4c36-8970-b87c90101139	Frites + Poulet	Frites + Poulet	3000	0.00	f	f	t	12	brun	SYL-056	2026-10-06 10:44:50.869284+00	2026-10-23 11:43:19.653979+00
934dde37-9033-45e6-86ed-7cdd2215b18e	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Dah + Poulet	Kabato Dah + Poulet	3000	0.00	f	f	t	5	ambre	SYL-005	2026-10-06 10:44:50.661623+00	2026-10-23 11:43:19.653981+00
ad312dc8-07cc-4429-ab36-054466502320	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Légume + Poulet	Sce Légume + Poulet	3000	0.00	f	f	t	10	vert	SYL-025	2026-10-06 10:44:50.741039+00	2026-10-23 11:43:19.653983+00
b3b6071a-76d0-4318-ab97-4a61d8a8ba8d	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Dah + Tripe	Kabato Dah + Tripe	3000	0.00	f	f	t	2	ambre	SYL-002	2026-10-06 10:44:50.647788+00	2026-10-23 11:43:19.653986+00
ba286914-b27e-4b33-980d-9e768e8b6569	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Légume + Boeuf	Sauce Légume + Boeuf	3000	0.00	f	f	t	9	vert	SYL-024	2026-10-06 10:44:50.737547+00	2026-10-23 11:43:19.653988+00
cd5cc4d5-6a6b-45d7-9c3d-9b4d5274d955	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Lafri + Tripe	Kabato Lafri + Tripe	3000	0.00	f	f	t	3	ambre	SYL-003	2026-10-06 10:44:50.652942+00	2026-10-23 11:43:19.65399+00
d74871da-b9f7-4a56-9a8a-9519599bf1be	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname frite + Poulet	Ign.Frite + Poulet	3000	0.00	f	f	t	7	brun	SYL-051	2026-10-06 10:44:50.851657+00	2026-10-23 11:43:19.653993+00
da7a9d7b-64d7-46e9-9a66-fb411d1976e5	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Poulet	Salade Pan. + Poulet	3000	0.00	f	f	t	2	cyan	SYL-033	2026-10-06 10:44:50.776112+00	2026-10-23 11:43:19.653995+00
e2551239-6d21-4a43-aac3-f435b261884e	8f3be9d2-6b4b-4c36-8970-b87c90101139	Frites + Boeuf	Frites + Boeuf	3000	0.00	f	f	t	11	brun	SYL-055	2026-10-06 10:44:50.866065+00	2026-10-23 11:43:19.653998+00
eef3b439-112e-485e-a7b6-0d7cd40198bf	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Sauce Feuille + Poulet	Sce Feuille + Poulet	3000	0.00	f	f	t	2	vert	SYL-017	2026-10-06 10:44:50.712304+00	2026-10-23 11:43:19.654+00
f2ceb9f5-5bbe-4b7d-8f8d-87fa4e9cc0db	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Kope + Boeuf	Kabato Kope + Boeuf	3000	0.00	f	f	t	7	ambre	SYL-007	2026-10-06 10:44:50.669837+00	2026-10-23 11:43:19.654002+00
f7e925d5-6ce1-4a66-90d5-d48e28cec819	8f3be9d2-6b4b-4c36-8970-b87c90101139	Igname bouillie + Boeuf	Ign.Bouillie + Boeuf	3000	0.00	f	f	t	1	brun	SYL-045	2026-10-06 10:44:50.830816+00	2026-10-23 11:43:19.654005+00
fac18978-1efd-4b64-99a7-75758a3d73c6	8f3be9d2-6b4b-4c36-8970-b87c90101139	Attiéké + Boeuf	Attiéké + Boeuf	3000	0.00	f	f	t	16	brun	SYL-060	2026-10-06 10:44:50.88399+00	2026-10-23 11:43:19.654007+00
fbb74d1d-e719-4478-b4fb-df4a903e41d5	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Kope + Poulet	Kabato Kope + Poulet	3000	0.00	f	f	t	4	ambre	SYL-004	2026-10-06 10:44:50.657034+00	2026-10-23 11:43:19.65401+00
c151009a-e385-4f46-a31b-6e1d536c093c	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou + Pistache bœuf	Foutou+Pistache bœuf	3500	0.00	f	f	t	99	ardoise	SYL-081	2026-10-23 11:43:19.677259+00	2026-10-23 11:43:19.677267+00
d198ad03-c605-4e0b-a84b-dacac22eac4e	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou + Pistache poulet	Foutou+Pistache poul	3500	0.00	f	f	t	99	ardoise	SYL-082	2026-10-23 11:43:19.681888+00	2026-10-23 11:43:19.681898+00
d354b5f0-e3a9-4024-9a11-6524de50706c	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou + Pistache poisson	Foutou+Pistache pois	3500	0.00	f	f	t	99	ardoise	SYL-083	2026-10-23 11:43:19.685048+00	2026-10-23 11:43:19.68506+00
0c4413d8-507b-4f42-a29f-5b87d1c6d4eb	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou + Pistache mouton	Foutou+Pistache mout	4000	0.00	f	f	t	99	ardoise	SYL-084	2026-10-23 11:43:19.688124+00	2026-10-23 11:43:19.688133+00
03f09170-0f20-493b-afb8-5082ee95b407	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz pistache + Poulet	Riz pistache+Poulet	3000	0.00	f	f	t	99	vert	SYL-085	2026-10-23 11:43:19.757113+00	2026-10-23 11:43:19.757127+00
18da79f3-6d8c-4f4c-a025-53b6d1bd36c0	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz pistache + Bœuf	Riz pistache + Bœuf	3000	0.00	f	f	t	99	vert	SYL-086	2026-10-23 11:43:19.760388+00	2026-10-23 11:43:19.760399+00
30179ad5-5045-4cf3-a666-9da609d74519	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz pistache + Mouton	Riz pistache+Mouton	4000	0.00	f	f	t	99	vert	SYL-087	2026-10-23 11:43:19.763766+00	2026-10-23 11:43:19.763803+00
c227722f-b1c2-4c4b-b00a-33424082f995	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz pistache + Poisson	Riz pistache+Poisson	4000	0.00	f	f	t	99	vert	SYL-088	2026-10-23 11:43:19.766759+00	2026-10-23 11:43:19.766773+00
3711b33e-f1bf-4416-91ea-5a85e467fe7b	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou graine + Bœuf	Foutou graine + Bœuf	3500	0.00	f	f	t	99	ardoise	SYL-089	2026-10-23 11:43:19.77026+00	2026-10-23 11:43:19.770272+00
176b9a0f-e557-43fa-8d36-5b111810a5e2	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou graine + Poulet	Foutou graine+Poulet	3500	0.00	f	f	t	99	ardoise	SYL-090	2026-10-23 11:43:19.773121+00	2026-10-23 11:43:19.773132+00
17f0a5d7-b947-44af-8d36-5d17846b8fe8	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou graine + Mouton	Foutou graine+Mouton	4000	0.00	f	f	t	99	ardoise	SYL-091	2026-10-23 11:43:19.775687+00	2026-10-23 11:43:19.775699+00
4aa4a646-b2c9-4ac8-8253-71a9b459eaec	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou graine + Poisson	Foutou graine+Poisso	3500	0.00	f	f	t	99	ardoise	SYL-092	2026-10-23 11:43:19.778857+00	2026-10-23 11:43:19.77887+00
d1e25ad6-24a2-49c6-a9a0-ba42e55caa59	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz graine + Poulet	Riz graine + Poulet	3000	0.00	f	f	t	99	vert	SYL-093	2026-10-23 11:43:19.781856+00	2026-10-23 11:43:19.781867+00
e124aaf5-e8c4-4540-a893-6c1bda0142e1	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz graine + Poisson	Riz graine + Poisson	3000	0.00	f	f	t	99	vert	SYL-094	2026-10-23 11:43:19.78482+00	2026-10-23 11:43:19.784831+00
48028a40-bf68-4e9b-a730-8b1aaac57cc2	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz graine + Bœuf	Riz graine + Bœuf	3000	0.00	f	f	t	99	vert	SYL-095	2026-10-23 11:43:19.787576+00	2026-10-23 11:43:19.787589+00
6b0fb042-32f2-49f5-980a-85f6fae8bae4	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz graine + Mouton	Riz graine + Mouton	4000	0.00	f	f	t	99	vert	SYL-096	2026-10-23 11:43:19.790343+00	2026-10-23 11:43:19.790356+00
8ae95388-062b-4bd6-8380-2579f4255713	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz graine + Poisson fumé	Riz graine+Pois.fumé	3500	0.00	f	f	t	99	vert	SYL-097	2026-10-23 11:43:19.793107+00	2026-10-23 11:43:19.793118+00
9aa4fbc0-8453-4000-9a0c-722fd3b0e285	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou djougblé + Poulet	Foutou djougblé+Poul	3500	0.00	f	f	t	99	ardoise	SYL-098	2026-10-23 11:43:19.795505+00	2026-10-23 11:43:19.795515+00
5320f791-91f4-4d1d-9c34-c548579ce7d4	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou djougblé + Bœuf	Foutou djougblé+Bœuf	3500	0.00	f	f	t	99	ardoise	SYL-099	2026-10-23 11:43:19.797942+00	2026-10-23 11:43:19.797951+00
93d818db-0e5e-44a6-913b-379b64d489ae	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou djougblé + Mouton	Foutou djougblé+Mout	4000	0.00	f	f	t	99	ardoise	SYL-100	2026-10-23 11:43:19.800728+00	2026-10-23 11:43:19.800739+00
2df7ac91-2836-49ed-ace0-40ca1cb82fc0	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou djougblé + Poisson	Foutou djougblé+Pois	3500	0.00	f	f	t	99	ardoise	SYL-101	2026-10-23 11:43:19.803756+00	2026-10-23 11:43:19.803765+00
6a581cd8-87d4-47f5-9589-ad5d45634fb3	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz djougblé + Poulet	Riz djougblé+Poulet	3000	0.00	f	f	t	99	vert	SYL-102	2026-10-23 11:43:19.806505+00	2026-10-23 11:43:19.806516+00
22956d43-3013-43b2-a1ce-0480e9abec6a	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz djougblé + Poisson	Riz djougblé+Poisson	3500	0.00	f	f	t	99	vert	SYL-103	2026-10-23 11:43:19.80914+00	2026-10-23 11:43:19.809152+00
fd3df342-68dd-4034-840a-98ce31f9c9b9	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz djougblé + Mouton	Riz djougblé+Mouton	4000	0.00	f	f	t	99	vert	SYL-104	2026-10-23 11:43:19.811755+00	2026-10-23 11:43:19.811764+00
fd86fafa-5bc2-4e8e-8c1c-99f3d1d3bc62	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz djougblé + Bœuf	Riz djougblé + Bœuf	3000	0.00	f	f	t	99	vert	SYL-105	2026-10-23 11:43:19.8145+00	2026-10-23 11:43:19.814511+00
0ae6808c-7e1e-49f0-856a-ebfe2232965b	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou gouagouassou + Poulet	Foutou gouagouassou+	3500	0.00	f	f	t	99	ardoise	SYL-106	2026-10-23 11:43:19.817264+00	2026-10-23 11:43:19.817275+00
4b89591b-e945-4e94-a7c9-8d1aa2d1c7ca	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou gouagouassou + Bœuf	Foutou gouagouassou+	3500	0.00	f	f	t	99	ardoise	SYL-107	2026-10-23 11:43:19.81977+00	2026-10-23 11:43:19.819804+00
8b637a4c-48a2-4b14-b5c5-e233a972a424	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou gouagouassou + Mouton	Foutou gouagouassou+	4000	0.00	f	f	t	99	ardoise	SYL-108	2026-10-23 11:43:19.822119+00	2026-10-23 11:43:19.822127+00
ab541db9-d472-4db5-b3aa-ffc75fb46468	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou gouagouassou + Poisson	Foutou gouagouassou+	3500	0.00	f	f	t	99	ardoise	SYL-109	2026-10-23 11:43:19.824378+00	2026-10-23 11:43:19.824388+00
574e5b14-a2df-47a2-96e1-d48eecbc82a7	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz gouagouassou + Poulet	Riz gouagouassou+Pou	3000	0.00	f	f	t	99	vert	SYL-110	2026-10-23 11:43:19.826551+00	2026-10-23 11:43:19.826561+00
44888ce3-3f92-46b1-8fd1-1ffe6c925938	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz gouagouassou + Mouton	Riz gouagouassou+Mou	4000	0.00	f	f	t	99	vert	SYL-111	2026-10-23 11:43:19.8289+00	2026-10-23 11:43:19.828908+00
1670d48a-5aa8-484b-8d51-87c0552f423d	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz gouagouassou + Poisson	Riz gouagouassou+Poi	3500	0.00	f	f	t	99	vert	SYL-112	2026-10-23 11:43:19.831179+00	2026-10-23 11:43:19.831189+00
b61d7f7b-66b0-4365-9ba9-07b046e06a06	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz gouagouassou + Bœuf	Riz gouagouassou+Bœu	3000	0.00	f	f	t	99	vert	SYL-113	2026-10-23 11:43:19.83367+00	2026-10-23 11:43:19.83368+00
578fbb1b-8dea-4372-919e-464656bcc8e4	8c3313e1-5e72-4262-9eed-79fb512a9661	Foufou sauce claire + Poulet	Foufou sauce claire+	3500	0.00	f	f	t	99	ardoise	SYL-114	2026-10-23 11:43:19.836183+00	2026-10-23 11:43:19.836193+00
c0fd4f28-d8a7-45db-9637-1ad10947cba0	8c3313e1-5e72-4262-9eed-79fb512a9661	Foufou sauce claire + Bœuf	Foufou sauce claire+	3500	0.00	f	f	t	99	ardoise	SYL-115	2026-10-23 11:43:19.838394+00	2026-10-23 11:43:19.838404+00
6bf08757-24e5-4f49-8c97-1d3ff4ce8445	8c3313e1-5e72-4262-9eed-79fb512a9661	Foutou sauce claire + Mouton	Foutou sauce claire+	4000	0.00	f	f	t	99	ardoise	SYL-116	2026-10-23 11:43:19.84059+00	2026-10-23 11:43:19.840602+00
33ba3796-33d9-43ae-87f2-bade3552ff07	8c3313e1-5e72-4262-9eed-79fb512a9661	Foufou sauce claire + Poisson fumé	Foufou sauce claire+	3500	0.00	f	f	t	99	ardoise	SYL-117	2026-10-23 11:43:19.843177+00	2026-10-23 11:43:19.843187+00
ff312382-ff3c-4870-a9cc-a0d94858cf22	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz sauce claire + Bœuf	Riz sauce claire+Bœu	3000	0.00	f	f	t	99	vert	SYL-118	2026-10-23 11:43:19.845859+00	2026-10-23 11:43:19.84587+00
89acb320-982c-45ac-8675-16e846d5dcf7	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz sauce claire + Poisson	Riz sauce claire+Poi	3500	0.00	f	f	t	99	vert	SYL-119	2026-10-23 11:43:19.848596+00	2026-10-23 11:43:19.848605+00
5909c2e0-82a6-411f-bf64-f750508d3e15	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz sauce claire + Mouton	Riz sauce claire+Mou	4000	0.00	f	f	t	99	vert	SYL-120	2026-10-23 11:43:19.851483+00	2026-10-23 11:43:19.851495+00
eab3cf4c-79d6-462d-af6e-27f334337e7a	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Riz sauce claire + Poulet	Riz sauce claire+Pou	3000	0.00	f	f	t	99	vert	SYL-121	2026-10-23 11:43:19.85413+00	2026-10-23 11:43:19.854139+00
36140fcb-5a02-4e11-87ea-2244e7f02f00	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Dah riz + Poulet	Dah riz + Poulet	3000	0.00	f	f	t	99	vert	SYL-122	2026-10-23 11:43:19.856438+00	2026-10-23 11:43:19.856448+00
e8200d8e-fe2d-4773-90e0-4dfb57095ba9	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Dah riz + Bœuf	Dah riz + Bœuf	3000	0.00	f	f	t	99	vert	SYL-123	2026-10-23 11:43:19.858601+00	2026-10-23 11:43:19.858612+00
06698559-0c78-4538-a68a-f9fc073f8ee7	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Dah riz + Mouton	Dah riz + Mouton	4000	0.00	f	f	t	99	vert	SYL-124	2026-10-23 11:43:19.861205+00	2026-10-23 11:43:19.861214+00
5617cdc0-98fd-4866-a33b-9571696ab1e5	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Dah riz + Poisson	Dah riz + Poisson	3500	0.00	f	f	t	99	vert	SYL-125	2026-10-23 11:43:19.863387+00	2026-10-23 11:43:19.863396+00
3b88851d-6135-478b-ae23-72cdc60db21c	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Dah + Bœuf	Kabato Dah + Bœuf	3000	0.00	f	f	t	99	ambre	SYL-126	2026-10-23 11:43:19.865701+00	2026-10-23 11:43:19.865711+00
0c8c099a-1d4b-4c78-be70-a2f846f9ce63	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Dah + Mouton	Kabato Dah + Mouton	4000	0.00	f	f	t	14	ambre	SYL-014	2026-10-06 10:44:50.697568+00	2026-10-23 11:43:19.8689+00
2c470520-ac57-4c94-bc51-2e952fe1ab21	c10d7361-d445-4d51-a087-7e05d6aae6cd	Kabato Dah + Poisson	Kabato Dah + Poisson	3500	0.00	f	f	t	11	ambre	SYL-011	2026-10-06 10:44:50.685038+00	2026-10-23 11:43:19.86891+00
dbbddcfa-2700-4728-9493-265036c0f5f6	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Feuille riz + Poulet	Feuille riz + Poulet	3000	0.00	f	f	t	99	vert	SYL-127	2026-10-23 11:43:19.870723+00	2026-10-23 11:43:19.870734+00
97683af9-8deb-4bfe-8a69-c115b265d9de	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Feuille riz + Bœuf	Feuille riz + Bœuf	3000	0.00	f	f	t	99	vert	SYL-128	2026-10-23 11:43:19.873191+00	2026-10-23 11:43:19.873201+00
988afbd3-9eb1-4d81-afcd-3458e0ffeea6	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Feuille riz + Mouton	Feuille riz + Mouton	4000	0.00	f	f	t	99	vert	SYL-129	2026-10-23 11:43:19.875459+00	2026-10-23 11:43:19.875469+00
ab821a9a-4978-4b9e-ad54-672a6e3d99fc	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Feuille riz + Poisson	Feuille riz+Poisson	3500	0.00	f	f	t	99	vert	SYL-130	2026-10-23 11:43:19.877992+00	2026-10-23 11:43:19.878001+00
c8c7ab09-63fd-4d61-ba67-9120765d4b2b	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Légumes riz + Poulet	Légumes riz + Poulet	3000	0.00	f	f	t	99	vert	SYL-131	2026-10-23 11:43:19.880195+00	2026-10-23 11:43:19.880205+00
ac9c133e-81d1-4eff-8f91-489e140066dc	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Légumes riz + Bœuf	Légumes riz + Bœuf	3000	0.00	f	f	t	99	vert	SYL-132	2026-10-23 11:43:19.882428+00	2026-10-23 11:43:19.882437+00
17287969-3735-43a8-930f-7b82994167e8	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Légumes riz + Mouton	Légumes riz + Mouton	4000	0.00	f	f	t	99	vert	SYL-133	2026-10-23 11:43:19.885051+00	2026-10-23 11:43:19.885062+00
f961c0e4-5a4b-4655-9e63-d8a9f273b5ea	b8b7d316-b32e-4aaa-87c2-cceb95c1ee2b	Légumes riz + Poisson	Légumes riz+Poisson	3500	0.00	f	f	t	99	vert	SYL-134	2026-10-23 11:43:19.887765+00	2026-10-23 11:43:19.887775+00
c26c8bca-782e-40ab-bc15-ed42ea1de1aa	b8baea0e-44c7-46eb-807f-a553310c5f7c	Couscous + Bœuf	Couscous + Bœuf	3000	0.00	f	f	t	99	orange	SYL-135	2026-10-23 11:43:19.890405+00	2026-10-23 11:43:19.890416+00
cd408593-401c-46d0-8507-624f0342f05a	b8baea0e-44c7-46eb-807f-a553310c5f7c	Couscous + Poisson	Couscous + Poisson	3500	0.00	f	f	t	3	orange	SYL-030	2026-10-06 10:44:50.762471+00	2026-10-23 11:43:19.893147+00
e2028931-16ad-47cd-a58c-03359d67788d	b8baea0e-44c7-46eb-807f-a553310c5f7c	Couscous + Mouton	Couscous + Mouton	4000	0.00	f	f	t	4	orange	SYL-031	2026-10-06 10:44:50.766153+00	2026-10-23 11:43:19.893158+00
7daa6be8-3b60-452f-8488-cd7f5a44b3ae	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Bœuf	Tchep + Bœuf	3000	0.00	f	f	t	99	rouge	SYL-136	2026-10-23 11:43:19.894807+00	2026-10-23 11:43:19.894816+00
c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Mouton	Tchep + Mouton	4000	0.00	f	f	t	4	rouge	SYL-040	2026-10-06 10:44:50.802707+00	2026-10-23 11:43:19.89739+00
28335d4b-c36a-4774-9cab-553727dc88ee	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Sosso 6000	Tchep + Sosso 6000	6000	0.00	f	f	t	99	rouge	SYL-137	2026-10-23 11:43:19.898633+00	2026-10-23 11:43:19.898642+00
239a4bae-bea4-40e5-98bd-85dfafa0ab4d	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Sosso 5500	Tchep + Sosso 5500	5500	0.00	f	f	t	99	rouge	SYL-138	2026-10-23 11:43:19.901017+00	2026-10-23 11:43:19.901027+00
38b3b46c-98fd-4600-ae3d-6d860fa5eaed	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Sosso 5000	Tchep + Sosso 5000	5000	0.00	f	f	t	99	rouge	SYL-139	2026-10-23 11:43:19.903233+00	2026-10-23 11:43:19.903242+00
ff82580c-7f61-43fc-a317-6e5bcbeca719	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Sosso 4500	Tchep + Sosso 4500	4500	0.00	f	f	t	99	rouge	SYL-140	2026-10-23 11:43:19.905409+00	2026-10-23 11:43:19.905419+00
e660378e-5bd1-45cb-9471-eba8487e218c	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Sosso 4000	Tchep + Sosso 4000	4000	0.00	f	f	t	99	rouge	SYL-141	2026-10-23 11:43:19.907651+00	2026-10-23 11:43:19.907661+00
0ea96d01-3bae-49d9-a310-a8134c4c1c67	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Sosso 3500	Tchep + Sosso 3500	3500	0.00	f	f	t	99	rouge	SYL-142	2026-10-23 11:43:19.90997+00	2026-10-23 11:43:19.909981+00
0f384836-61aa-41f0-9eca-f21c89c3ae9a	844d467e-f25a-4721-b050-f0aa823fe817	Tchep + Sosso 3000	Tchep + Sosso 3000	3000	0.00	f	f	t	99	rouge	SYL-143	2026-10-23 11:43:19.912225+00	2026-10-23 11:43:19.912233+00
a04b9537-8885-45f0-9619-c4df6d38cff9	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Bœuf	Sal.Pan. + Bœuf	3000	0.00	f	f	t	99	cyan	SYL-144	2026-10-23 11:43:19.914763+00	2026-10-23 11:43:19.914774+00
74da32a1-1f86-422a-afcf-f431b9765c75	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Mouton	Salade Pan. + Mouton	4000	0.00	f	f	t	5	cyan	SYL-036	2026-10-06 10:44:50.787126+00	2026-10-23 11:43:19.918032+00
e107e808-3fe7-4ec8-b425-00b515a6abe5	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Poisson	Sal.Pan. + Poisson	3000	0.00	f	f	t	99	cyan	SYL-145	2026-10-23 11:43:19.91957+00	2026-10-23 11:43:19.91958+00
df2a62c3-58d6-430f-b10e-45b0cb58cff1	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Sosso 5000	Sal.Pan.+Sosso 5000	5000	0.00	f	f	t	99	cyan	SYL-146	2026-10-23 11:43:19.921823+00	2026-10-23 11:43:19.921833+00
1ccc930c-4c9b-4e72-a8b9-da1012c9a30f	06c1be01-2539-411a-9a12-89674460c795	Salade Panachée + Sosso 4000	Sal.Pan.+Sosso 4000	4000	0.00	f	f	t	99	cyan	SYL-147	2026-10-23 11:43:19.924029+00	2026-10-23 11:43:19.924038+00
6c2bde92-5e59-4471-a9f0-4c3518bfc525	06c1be01-2539-411a-9a12-89674460c795	Salade Fraîche + Sosso 5000	Sal.Fraîche+Sosso 50	5000	0.00	f	f	t	99	cyan	SYL-148	2026-10-23 11:43:19.926199+00	2026-10-23 11:43:19.926209+00
93b1f693-b2ca-4ca6-8abd-bbd9abcfd971	06c1be01-2539-411a-9a12-89674460c795	Salade Fraîche + Sosso 4000	Sal.Fraîche+Sosso 40	4000	0.00	f	f	t	99	cyan	SYL-149	2026-10-23 11:43:19.928644+00	2026-10-23 11:43:19.928654+00
b7acc96a-f4f3-4722-b388-91a0d82cdfff	06c1be01-2539-411a-9a12-89674460c795	Salade Fraîche + Poisson braisé	Sal.Fraîche+Pois.Bra	5000	0.00	f	f	t	99	cyan	SYL-150	2026-10-23 11:43:19.930984+00	2026-10-23 11:43:19.930993+00
821840ca-5fb1-4524-8e46-cff9e1f2813b	06c1be01-2539-411a-9a12-89674460c795	Salade Fraîche + Mouton	Sal.Fraîche + Mouton	3500	0.00	f	f	t	99	cyan	SYL-151	2026-10-23 11:43:19.93362+00	2026-10-23 11:43:19.93363+00
9730e484-0913-497b-8663-b228822b3ddc	06c1be01-2539-411a-9a12-89674460c795	Salade Fraîche + Poulet	Sal.Fraîche + Poulet	3000	0.00	f	f	t	99	cyan	SYL-152	2026-10-23 11:43:19.936183+00	2026-10-23 11:43:19.936193+00
9011c9d2-8ebf-495d-b21f-bf0078edf101	06c1be01-2539-411a-9a12-89674460c795	Salade Fraîche + Bœuf	Sal.Fraîche + Bœuf	3000	0.00	f	f	t	99	cyan	SYL-153	2026-10-23 11:43:19.938467+00	2026-10-23 11:43:19.938475+00
a5a48573-591b-4c2a-8309-14d0046cdbe9	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Sosso 6000	Yassa + Sosso 6000	6000	0.00	f	f	t	99	rouge	SYL-154	2026-10-23 11:43:19.940634+00	2026-10-23 11:43:19.940643+00
af3be04d-99fb-4841-96be-dc328bcafbf4	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Sosso 5500	Yassa + Sosso 5500	5500	0.00	f	f	t	99	rouge	SYL-155	2026-10-23 11:43:19.942691+00	2026-10-23 11:43:19.9427+00
22ce35b9-eb8e-4266-9efd-1df179928fe7	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Sosso 5000	Yassa + Sosso 5000	5000	0.00	f	f	t	99	rouge	SYL-156	2026-10-23 11:43:19.944934+00	2026-10-23 11:43:19.944943+00
89d222ed-0310-4f2b-8f99-c4a23f6ae217	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Sosso 4500	Yassa + Sosso 4500	4500	0.00	f	f	t	99	rouge	SYL-157	2026-10-23 11:43:19.947164+00	2026-10-23 11:43:19.947173+00
e8b15a64-4e2d-421b-bddf-9c5a7601029a	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Sosso 4000	Yassa + Sosso 4000	4000	0.00	f	f	t	99	rouge	SYL-158	2026-10-23 11:43:19.949348+00	2026-10-23 11:43:19.949356+00
9e22a47d-c54b-444a-8bcc-76a86bdf420c	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Sosso 3500	Yassa + Sosso 3500	3500	0.00	f	f	t	99	rouge	SYL-159	2026-10-23 11:43:19.95238+00	2026-10-23 11:43:19.952391+00
16a4a62f-bcfd-435d-b061-3dfb4b8d4bd5	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Sosso 3000	Yassa + Sosso 3000	3000	0.00	f	f	t	99	rouge	SYL-160	2026-10-23 11:43:19.954746+00	2026-10-23 11:43:19.954757+00
5e0c5771-60b0-4f71-8e5e-087e30a7e179	844d467e-f25a-4721-b050-f0aa823fe817	Yassa + Bœuf	Yassa + Bœuf	3000	0.00	f	f	t	99	rouge	SYL-161	2026-10-23 11:43:19.957146+00	2026-10-23 11:43:19.957156+00
643f4827-4ce5-47b4-8823-5bd1d606e982	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Sosso 6000	P.Pois + Sosso 6000	6000	0.00	f	f	t	99	brun	SYL-162	2026-10-23 11:43:19.959827+00	2026-10-23 11:43:19.959839+00
ce629d3f-73b4-4bc1-aa6a-2ccb49044366	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Sosso 5000	P.Pois + Sosso 5000	5000	0.00	f	f	t	99	brun	SYL-163	2026-10-23 11:43:19.962495+00	2026-10-23 11:43:19.962505+00
2583530a-529b-42b0-987a-1db7b96d24fd	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Sosso 4500	P.Pois + Sosso 4500	4500	0.00	f	f	t	99	brun	SYL-164	2026-10-23 11:43:19.96511+00	2026-10-23 11:43:19.965121+00
708a41d7-0323-42ee-8725-a3ab898bd39d	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Sosso 4000	P.Pois + Sosso 4000	4000	0.00	f	f	t	99	brun	SYL-165	2026-10-23 11:43:19.967929+00	2026-10-23 11:43:19.96794+00
4f4a6067-f359-4422-bbbb-20f5aaded6b3	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Sosso 3500	P.Pois + Sosso 3500	3500	0.00	f	f	t	99	brun	SYL-166	2026-10-23 11:43:19.970676+00	2026-10-23 11:43:19.970687+00
b5fde150-980d-4922-82aa-71a971fbdc11	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Sosso 3000	P.Pois + Sosso 3000	3000	0.00	f	f	t	99	brun	SYL-167	2026-10-23 11:43:19.973438+00	2026-10-23 11:43:19.973449+00
9789ad02-8eb7-46f3-8ce5-cf30a399add6	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Mouton	Petit pois + Mouton	3500	0.00	f	f	t	26	brun	SYL-070	2026-10-06 10:44:50.920388+00	2026-10-23 11:43:19.975872+00
e328a67e-40df-4b18-903d-a5938ad83d56	8f3be9d2-6b4b-4c36-8970-b87c90101139	Petit pois + Bœuf	Petit pois + Bœuf	3000	0.00	f	f	t	99	brun	SYL-168	2026-10-23 11:43:19.977462+00	2026-10-23 11:43:19.977472+00
b6337c04-bc7e-4f77-ae64-4fd7e717784b	37f33917-e947-438e-a046-1530d7dced56	Sosso 6000	Sosso 6000	6000	0.00	f	f	t	99	ardoise	SYL-169	2026-10-23 11:43:19.979764+00	2026-10-23 11:43:19.979773+00
37ac1c8b-58e7-4508-857d-d684763c2a05	37f33917-e947-438e-a046-1530d7dced56	Sosso 6500	Sosso 6500	6500	0.00	f	f	t	99	ardoise	SYL-170	2026-10-23 11:43:19.981996+00	2026-10-23 11:43:19.982006+00
93418cf7-cec2-4441-925a-2917ba67479a	37f33917-e947-438e-a046-1530d7dced56	Sosso 7000	Sosso 7000	7000	0.00	f	f	t	99	ardoise	SYL-171	2026-10-23 11:43:19.984491+00	2026-10-23 11:43:19.984501+00
\.


--
-- Data for Name: purchase_invoices; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.purchase_invoices (id, invoice_number, supplier_id, received_by_user_id, delivery_date, total_amount_xof, status, notes, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: purchase_items; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.purchase_items (id, purchase_invoice_id, raw_material_id, quantity, unit_price_xof, total_price_xof, packaging_qty, units_per_packaging, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: purchase_request_lines; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.purchase_request_lines (id, request_id, article_id, requested_quantity, approved_quantity, unit_price_xof, received_quantity, received_cost_xof, stock_movement_id) FROM stdin;
\.


--
-- Data for Name: purchase_requests; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.purchase_requests (id, number, status, requested_by_user_id, note, estimated_total_xof, approved_total_xof, approved_by_user_id, approved_at, disbursed_xof, disbursed_by_user_id, disbursed_at, received_total_xof, received_by_user_id, received_at, supplier, closed_reason, closed_by_user_id, closed_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: raw_material_movements; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.raw_material_movements (id, raw_material_id, user_id, type, quantity, quantity_after, unit_cost_xof, reason, purchase_invoice_id, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: raw_materials; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.raw_materials (id, name, category, unit, current_stock, alert_threshold, cost_price_xof, average_cost_xof, default_supplier_id, is_active, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: restaurant_tables; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.restaurant_tables (id, label, zone, seats, sort_order, is_active, created_at, updated_at) FROM stdin;
cb2c0d43-facf-4ddc-bda4-b99afa2ec289	Table 1	Salle	4	0	t	2026-10-06 11:01:07.053157+00	2026-10-06 11:01:07.053317+00
47e6e141-b494-4813-8c9c-3c455c91a422	Table 2	Salle	4	0	t	2026-10-06 11:01:46.981068+00	2026-10-06 11:01:46.981078+00
17c3433b-b05c-4e93-9b13-56834f10ea3a	Table 3	Salle	4	0	t	2026-10-06 11:01:53.40446+00	2026-10-06 11:01:53.404472+00
830e098a-77ec-4022-8736-ed94c5fe3cfe	Table 4	Salle	4	0	t	2026-10-06 11:01:59.234459+00	2026-10-06 11:01:59.234468+00
05aa9ad5-594d-4926-8d1a-508eec179caf	Table 5	Salle	4	0	t	2026-10-06 11:02:03.932027+00	2026-10-06 11:02:03.932035+00
f3904853-0688-4341-9830-a0a9716161bc	Table 6	Salle	4	0	t	2026-10-06 11:02:08.613185+00	2026-10-06 11:02:08.613194+00
083e37af-15ee-44be-9b2e-21eef62593fc	Table 7	Salle	4	0	t	2026-10-06 11:02:18.229812+00	2026-10-06 11:02:18.229823+00
259ae2af-e711-442b-a6c7-1de4b25711ba	Table 8	Salle	4	0	t	2026-10-06 11:02:24.040905+00	2026-10-06 11:02:24.040915+00
6cf24b95-3c1e-473d-bdd8-2f22c321b558	Table 9	Salle	4	0	t	2026-10-06 11:02:28.879972+00	2026-10-06 11:02:28.879983+00
d3602f9e-0bc4-4386-8e39-367925cb190a	Table 10	Salle	4	0	t	2026-10-06 11:02:34.240866+00	2026-10-06 11:02:34.240881+00
\.


--
-- Data for Name: sequence_counters; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.sequence_counters (key, value) FROM stdin;
\.


--
-- Data for Name: settings; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.settings (key, value, updated_by, updated_at) FROM stdin;
vat.default_rate	"0.00"	\N	2026-10-03 17:22:50.180848+00
fne.point_of_sale	"point de vente 1"	\N	2026-10-29 10:59:11.468015+00
fne.establishment	"RESTAURANT CHEZ SYLLA PLUS"	\N	2026-10-29 10:59:11.468015+00
\.


--
-- Data for Name: stock_articles; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.stock_articles (id, name, category, unit, out_mode, quantity, avg_cost_xof, alert_threshold, is_active, note, created_at, updated_at) FROM stdin;
6a7dc7ed-7a51-4954-9d06-68b9bd08d74c	Eau Celeste 0,5 L	BOISSON	bouteille	RECIPE	0.000	111.11	\N	t	\N	2026-10-20 15:03:14.558718+00	2026-10-24 23:29:14.458045+00
6860e5c8-8643-46d2-a6e9-bfe6e9fc80a0	Eau Celeste 1,5 L	BOISSON	bouteille	RECIPE	0.000	266.66	\N	t	\N	2026-10-20 15:03:14.565711+00	2026-10-24 23:29:14.458045+00
0edc867d-1dfa-4bdc-8988-8401299297b9	Sucrerie bouteille 33 cl	BOISSON	bouteille	RECIPE	0.000	187.50	\N	t	\N	2026-10-20 15:03:14.571148+00	2026-10-24 23:29:14.458045+00
fb615c0d-0da1-44bb-9a49-c1e3a3d772b2	Canette sucrerie (mélange)	BOISSON	canette	RECIPE	0.000	300.00	\N	t	\N	2026-10-20 15:03:14.577423+00	2026-10-24 23:29:14.458045+00
b9e7f197-7df5-4ffd-ab80-e033bfe823bd	Canette Ivorio	BOISSON	canette	RECIPE	0.000	583.33	\N	t	\N	2026-10-20 15:03:14.583686+00	2026-10-24 23:29:14.458045+00
cacb80fe-d0f9-4801-b6c6-fefe8703dd50	Ail	EPICERIE	kg	INVENTORY	0.000	1500.00	\N	t	\N	2026-10-20 15:03:14.691586+00	2026-10-24 23:29:14.458045+00
658b4aa4-8cd2-4a1e-8b42-fe19c5f38073	Carotte	EPICERIE	kg	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.694727+00	2026-10-24 23:29:14.458045+00
91655ec4-b706-4fbe-a456-308fb82a5f42	Aubergine	EPICERIE	kg	INVENTORY	0.000	300.00	\N	t	\N	2026-10-20 15:03:14.697786+00	2026-10-24 23:29:14.458045+00
54d0c628-235d-4f09-b026-ab073c650261	Jus de citron	BOISSON	bouteille	RECIPE	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.620855+00	2026-10-24 23:29:14.458045+00
77136ac2-37cc-4d12-9ff4-95a07afeeb46	Courgette	EPICERIE	kg	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.710146+00	2026-10-24 23:29:14.458045+00
bd4c5793-fb0b-4f57-adf4-7a9c98df4473	Poivron	EPICERIE	kg	INVENTORY	0.000	1300.00	\N	t	\N	2026-10-20 15:03:14.713708+00	2026-10-24 23:29:14.458045+00
42295a23-2514-4477-be0b-a8491aa6d3c9	Haricot vert	EPICERIE	kg	INVENTORY	0.000	1500.00	\N	t	\N	2026-10-20 15:03:14.716757+00	2026-10-24 23:29:14.458045+00
fb04ec54-f6d9-49d8-ab2c-d58903c53471	Concombre	EPICERIE	pièce	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.727444+00	2026-10-24 23:29:14.458045+00
78c049e1-b3e5-4e52-8d22-b2741a9016de	Gombo	EPICERIE	tas	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.730943+00	2026-10-24 23:29:14.458045+00
c36db8db-6827-4e54-8bfc-9c863d691b44	Gombo de kopè	EPICERIE	tas	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.734212+00	2026-10-24 23:29:14.458045+00
4955cd40-1990-4117-9970-679efe21a6aa	Feuille de dah	EPICERIE	tas	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.73739+00	2026-10-24 23:29:14.458045+00
8161cf8a-5c27-4f7e-a46e-be18f876a61e	Chou	EPICERIE	pièce	INVENTORY	0.000	700.00	\N	t	\N	2026-10-20 15:03:14.700866+00	2026-10-24 23:29:14.458045+00
c8128150-354d-4a2b-904a-f8b5841f9b9b	Feuille oignon, persil, poireau	EPICERIE	tas	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.744229+00	2026-10-24 23:29:14.458045+00
66fd45cd-cfbf-480d-aa61-a86a19e0b536	Assaisonnement vert	EPICERIE	tas	INVENTORY	0.000	150.00	\N	t	\N	2026-10-20 15:03:14.747304+00	2026-10-24 23:29:14.458045+00
fa786d22-6359-4d07-8fbb-0a1c15871741	Graine de palme	EPICERIE	kg	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.750614+00	2026-10-24 23:29:14.458045+00
f466a03f-6e7a-4557-a90b-07b623eb529c	Huile	EPICERIE	litre	INVENTORY	0.000	1060.00	\N	t	\N	2026-10-20 15:03:14.760185+00	2026-10-24 23:29:14.458045+00
2185f501-e5d2-467a-a562-ec093dce56a9	Huile rouge	EPICERIE	litre	INVENTORY	0.000	2000.00	\N	t	\N	2026-10-20 15:03:14.763115+00	2026-10-24 23:29:14.458045+00
acf15bb3-a9c2-4d50-b450-9001cbda285e	Poisson sec	EPICERIE	kg	INVENTORY	0.000	667.00	\N	t	deux lignes dans l'Excel (143 et 667)	2026-10-20 15:03:14.782278+00	2026-10-24 23:29:14.458045+00
4a635e05-20c0-4a7b-b7a9-d531fa89ff4a	Viande (foufou)	EPICERIE	kg	INVENTORY	0.000	4500.00	\N	t	\N	2026-10-20 15:03:14.792468+00	2026-10-24 23:29:14.458045+00
f62f58d8-b821-4425-8d60-e8d8dfa160d2	Tripe	EPICERIE	kg	INVENTORY	0.000	2000.00	\N	t	\N	2026-10-20 15:03:14.795819+00	2026-10-24 23:29:14.458045+00
7966dbe5-910e-4b4b-8ecb-5c3ba231ddd1	Tête de bœuf	EPICERIE	pièce	INVENTORY	0.000	1500.00	\N	t	\N	2026-10-20 15:03:14.798878+00	2026-10-24 23:29:14.458045+00
6e90a97b-a674-47f8-ad60-5f54335f9c54	Crabe	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.802132+00	2026-10-24 23:29:14.458045+00
08216391-c95a-4a63-a95a-36d808801419	Crevette sèche	EPICERIE	sachet	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.805323+00	2026-10-24 23:29:14.458045+00
91e267ee-ce06-4737-b297-5c8ba510f986	Magne fumé	EPICERIE	pièce	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.809273+00	2026-10-24 23:29:14.458045+00
a60a863f-69b3-4b5e-a240-ebe1b9f31728	Magne sec	EPICERIE	pièce	INVENTORY	0.000	15.00	\N	t	\N	2026-10-20 15:03:14.812306+00	2026-10-24 23:29:14.458045+00
ba4a683e-f3b6-4d87-a415-a9b83d57ec2a	Djoumgblé	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.815373+00	2026-10-24 23:29:14.458045+00
7e10c02e-5781-4bf1-8b6c-237a8085f663	Akpi	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.821379+00	2026-10-24 23:29:14.458045+00
031058df-6ea2-4838-b0d8-91662194502d	Fèfè	EPICERIE	tas	INVENTORY	0.000	2000.00	\N	t	\N	2026-10-20 15:03:14.824896+00	2026-10-24 23:29:14.458045+00
c65a626e-991a-4bfa-85a8-b7d23cd364c0	Kplo	EPICERIE	tas	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.827895+00	2026-10-24 23:29:14.458045+00
9ba95d7c-7efc-4521-9aba-6b401c7223f0	Djet	EPICERIE	pièce	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.833717+00	2026-10-24 23:29:14.458045+00
ce3aea34-ecd0-4f58-bd2b-9716b768e513	Farine pâtissière	EPICERIE	kg	INVENTORY	0.000	700.00	\N	t	\N	2026-10-20 15:03:14.840065+00	2026-10-24 23:29:14.458045+00
ba1434e3-3dfc-4aec-9d38-c1e459c2b16e	Pain	EPICERIE	pièce	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.845963+00	2026-10-24 23:29:14.458045+00
b8d83cb4-cc9b-4bd1-8763-c6a92eff551c	Fruits	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.848443+00	2026-10-24 23:29:14.458045+00
083f2621-ca1f-44a5-9ad1-df1debb076c4	Citron / thé	EPICERIE	sachet	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.851187+00	2026-10-24 23:29:14.458045+00
6cd46f2c-73ef-4ed0-a1d6-8be26e1eea13	Mayonnaise	EPICERIE	pot	INVENTORY	0.000	2300.00	\N	t	\N	2026-10-20 15:03:14.854179+00	2026-10-24 23:29:14.458045+00
58cbdd9d-2474-4085-9907-8e11f91d8b12	Maggi tablette	EPICERIE	cube	INVENTORY	0.000	26.70	\N	t	\N	2026-10-20 15:03:14.867098+00	2026-10-24 23:29:14.458045+00
bf9af96c-7222-4983-a8eb-2315a26543be	Maggi poulet	EPICERIE	cube	INVENTORY	0.000	26.70	\N	t	\N	2026-10-20 15:03:14.870142+00	2026-10-24 23:29:14.458045+00
b03a9aca-f913-4695-b910-95872ec2d660	Maggi crevette	EPICERIE	cube	INVENTORY	0.000	26.70	\N	t	\N	2026-10-20 15:03:14.873328+00	2026-10-24 23:29:14.458045+00
33d39945-93b2-4199-bd3c-519cfc8c5e39	Chapelet de maggi	EPICERIE	chapelet	INVENTORY	0.000	50.00	\N	t	\N	2026-10-20 15:03:14.876758+00	2026-10-24 23:29:14.458045+00
21ee85c8-23cd-4276-8094-56e001b97b51	Doli poulet	EPICERIE	sachet	INVENTORY	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.880144+00	2026-10-24 23:29:14.458045+00
5282250a-6c57-4708-a889-44d594c6875c	Djonké	EPICERIE	sachet	INVENTORY	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.883652+00	2026-10-24 23:29:14.458045+00
fd84ec0f-4272-49af-a43d-a26ff87ec313	Adja rouge	EPICERIE	sachet	INVENTORY	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.887542+00	2026-10-24 23:29:14.458045+00
0b8c3163-f9d3-4663-8308-acb9cc33130b	Adja marron	EPICERIE	sachet	INVENTORY	0.000	150.00	\N	t	\N	2026-10-20 15:03:14.891802+00	2026-10-24 23:29:14.458045+00
e4f32563-95ac-4528-9343-e44e7a0e34b9	Colorant alimentaire	EPICERIE	sachet	INVENTORY	0.000	15.00	\N	t	\N	2026-10-20 15:03:14.899722+00	2026-10-24 23:29:14.458045+00
f412fad2-4aff-4442-8be9-ab65399d351d	Gaz	ENERGIE	bouteille	INVENTORY	0.000	14500.00	\N	t	\N	2026-10-20 15:03:14.903192+00	2026-10-24 23:29:14.458045+00
dde345c3-3925-4746-a81a-998b450b5f75	Take away	EMBALLAGE	pièce	INVENTORY	0.000	60.00	\N	t	\N	2026-10-20 15:03:14.907127+00	2026-10-24 23:29:14.458045+00
5235869f-45bb-4a01-8c03-d0973987cdaf	Bol de sauce	EMBALLAGE	pièce	INVENTORY	0.000	70.00	\N	t	\N	2026-10-20 15:03:14.910651+00	2026-10-24 23:29:14.458045+00
84f5ad21-a829-4a60-b575-e24a5e92cd45	Cuillère + fourchette	EMBALLAGE	paire	INVENTORY	0.000	10.00	\N	t	20 en avril	2026-10-20 15:03:14.914121+00	2026-10-24 23:29:14.458045+00
d09d64f4-764e-4c6f-9cc5-232cb6e9f12d	Sachet	EMBALLAGE	paquet	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.917647+00	2026-10-24 23:29:14.458045+00
9c44e792-4724-46eb-a278-875e6ce514a8	Orangina 50 cl	BOISSON	bouteille	RECIPE	0.000	416.70	\N	t	\N	2026-10-20 15:03:14.590811+00	2026-10-24 23:29:14.458045+00
21c0a4c6-64c9-4223-a0c3-fee4ef7ebd1f	Canette Cody's	BOISSON	canette	RECIPE	0.000	404.20	\N	t	\N	2026-10-20 15:03:14.596034+00	2026-10-24 23:29:14.458045+00
2cad3fbe-c8cf-4dc8-9a9c-3c39831d69e1	Jus de gingembre	BOISSON	bouteille	RECIPE	0.000	333.30	\N	t	\N	2026-10-20 15:03:14.602509+00	2026-10-24 23:29:14.458045+00
d9fbe76f-9256-4c7e-9f98-5f9a1f4b0c3d	Jus de bissap	BOISSON	bouteille	RECIPE	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.609452+00	2026-10-24 23:29:14.458045+00
c3165735-9157-4879-b272-a6807c36d677	Jus Tomy	BOISSON	bouteille	RECIPE	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.615222+00	2026-10-24 23:29:14.458045+00
25fd53a8-c277-418d-a596-b575ce7f784a	Jus de passion	BOISSON	bouteille	RECIPE	0.000	400.00	\N	t	\N	2026-10-20 15:03:14.627718+00	2026-10-24 23:29:14.458045+00
edba16c2-09c9-47b2-977e-82d92a6b0582	Lait / dêguê	BOISSON	bouteille	RECIPE	0.000	800.00	\N	t	\N	2026-10-20 15:03:14.634105+00	2026-10-24 23:29:14.458045+00
8ca7f94b-d3d9-4a5e-860b-6a500b0d3502	Capsule café expresso	BOISSON	capsule	RECIPE	0.000	200.00	\N	t	\N	2026-10-20 15:03:14.641906+00	2026-10-24 23:29:14.458045+00
bb8d7b4b-59c0-4e18-beb7-1b2862157061	Riz	EPICERIE	kg	INVENTORY	0.000	640.00	\N	t	\N	2026-10-20 15:03:14.649156+00	2026-10-24 23:29:14.458045+00
86c3f5af-81ec-4e55-86dd-9ec82033a69e	Couscous	EPICERIE	kg	INVENTORY	0.000	800.00	\N	t	\N	2026-10-20 15:03:14.654804+00	2026-10-24 23:29:14.458045+00
a92dd8ce-2c2f-46a0-9841-21082770840a	Pomme de terre	EPICERIE	kg	INVENTORY	0.000	520.00	\N	t	\N	2026-10-20 15:03:14.658748+00	2026-10-24 23:29:14.458045+00
6ba11eee-ba07-4a0e-b6e9-e3c43f76d328	Igname	EPICERIE	kg	INVENTORY	0.000	667.00	\N	t	\N	2026-10-20 15:03:14.668591+00	2026-10-24 23:29:14.458045+00
4ed510c1-89a1-4d6e-a0ee-3b3ccdcbe5f3	Attiéké	EPICERIE	boule	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.678444+00	2026-10-24 23:29:14.458045+00
0357a4f3-4c06-4275-9264-c70a25c374c1	Banane alloco	EPICERIE	régime	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.681601+00	2026-10-24 23:29:14.458045+00
90f3fed1-d9d3-4cdc-8651-c32bdb195963	Banane plantain (foufou)	EPICERIE	régime	INVENTORY	0.000	5000.00	\N	t	\N	2026-10-20 15:03:14.684771+00	2026-10-24 23:29:14.458045+00
2dfae7b6-8af0-481e-972f-d13c7d139ffd	Papier aluminium 3x50 m	EMBALLAGE	rouleau	INVENTORY	0.000	2650.00	\N	t	\N	2026-10-20 15:03:14.92109+00	2026-10-24 23:29:14.458045+00
47cf42cf-ed12-4072-a987-896474d9dfe1	Allumettes	EMBALLAGE	boîte	INVENTORY	0.000	166.60	\N	t	\N	2026-10-20 15:03:14.924978+00	2026-10-24 23:29:14.458045+00
5f7d46d7-7076-4470-bec7-543b954b10ec	Papier mouchoir	ENTRETIEN	paquet	INVENTORY	0.000	1988.00	\N	t	\N	2026-10-20 15:03:14.927912+00	2026-10-24 23:29:14.458045+00
c920af02-d2a9-45c2-865e-0a762ab89060	Essuie-tout	ENTRETIEN	rouleau	INVENTORY	0.000	566.66	\N	t	\N	2026-10-20 15:03:14.931039+00	2026-10-24 23:29:14.458045+00
10ac2feb-5520-4cf3-8e51-1e497e0a8a3c	Papier hygiénique	ENTRETIEN	paquet	INVENTORY	0.000	4100.00	\N	t	\N	2026-10-20 15:03:14.934185+00	2026-10-24 23:29:14.458045+00
0256ce42-3b91-4444-a638-5470e036ac71	Sac poubelle	ENTRETIEN	pièce	INVENTORY	0.000	200.00	\N	t	\N	2026-10-20 15:03:14.937648+00	2026-10-24 23:29:14.458045+00
7c9061ac-2a1d-4ff0-8680-75339e8917a4	Javel 8° 3 L	ENTRETIEN	bidon	INVENTORY	0.000	1366.60	\N	t	\N	2026-10-20 15:03:14.941623+00	2026-10-24 23:29:14.458045+00
f4b8119b-3431-4050-8c18-e8f9bf560a79	Javel 12° 3 L	ENTRETIEN	bidon	INVENTORY	0.000	1700.00	\N	t	\N	2026-10-20 15:03:14.945244+00	2026-10-24 23:29:14.458045+00
be80260f-fc61-4ff9-a7d5-9845b9dd861c	Savon liquide 3 L	ENTRETIEN	bidon	INVENTORY	0.000	1983.30	\N	t	\N	2026-10-20 15:03:14.948748+00	2026-10-24 23:29:14.458045+00
83dd5b03-3ab9-415f-a098-27a23a019245	Insecticide	ENTRETIEN	bombe	INVENTORY	0.000	812.50	\N	t	\N	2026-10-20 15:03:14.95224+00	2026-10-24 23:29:14.458045+00
71e8714d-dbf6-4323-ad9b-dadada8892f5	Chapeau de cuisine	ENTRETIEN	pièce	INVENTORY	0.000	35.00	\N	t	\N	2026-10-20 15:03:14.955755+00	2026-10-24 23:29:14.458045+00
02a19865-af2d-466d-9754-363c10dcda24	Piment sénbon	EPICERIE	tas	INVENTORY	1.000	1000.00	\N	t	\N	2026-10-20 15:03:14.776119+00	2026-10-29 15:46:47.836414+00
07ee94bb-1c62-4d20-b9e3-9b2aa9132f4a	Poulet pondeuse	PROTEINE	pièce	RECIPE	10.000	4000.00	\N	t	\N	2026-10-20 15:03:14.515927+00	2026-10-29 15:46:47.836423+00
08cb25bf-cdde-4549-9392-f4bf2a9d2909	Manioc	EPICERIE	kg	INVENTORY	2.000	1500.00	\N	t	500 en avril	2026-10-20 15:03:14.687907+00	2026-10-29 15:46:47.836425+00
0d45efe2-2e7f-4d3c-a266-7bb742479fac	Vinaigre blanc	EPICERIE	bouteille	INVENTORY	1.000	750.00	\N	t	\N	2026-10-20 15:03:14.860946+00	2026-10-29 15:46:47.836428+00
1cae06ac-04d4-4d22-a52d-487e50268463	Petit pois	EPICERIE	boîte	INVENTORY	1.000	2000.00	\N	t	\N	2026-10-20 15:03:14.720127+00	2026-10-29 15:46:47.836432+00
258570a6-aee0-4adb-a7e1-526f56b06506	Faux brochet	PROTEINE	pièce	RECIPE	10.000	800.00	\N	t	\N	2026-10-20 15:03:14.522143+00	2026-10-29 15:46:47.836434+00
26290d66-6767-41d8-ba7e-40916c397c90	Poisson frais (foufou)	EPICERIE	kg	INVENTORY	2.000	10000.00	\N	t	\N	2026-10-20 15:03:14.788574+00	2026-10-29 15:46:47.836437+00
2b2efe1b-6b47-4228-9508-82c43be96592	Piment garba	EPICERIE	tas	INVENTORY	1.000	1000.00	\N	t	\N	2026-10-20 15:03:14.772427+00	2026-10-29 15:46:47.836439+00
2e397e12-f4b0-4c25-96af-63ea19feb790	Piment en poudre	EPICERIE	sachet	INVENTORY	2.000	500.00	\N	t	\N	2026-10-20 15:03:14.779174+00	2026-10-29 15:46:47.836441+00
5deeb776-8c5f-48ec-9ef7-c55f2d51d15d	Poudre de maïs	EPICERIE	kg	INVENTORY	2.000	1000.00	\N	t	\N	2026-10-20 15:03:14.836613+00	2026-10-29 15:46:47.836444+00
5e5c8e90-160b-4766-abc5-0b06087c6456	Faux saumon	PROTEINE	morceau	RECIPE	10.000	500.00	\N	t	acheté entier à 2 500 F jusqu'en août, au morceau depuis	2026-10-20 15:03:14.538035+00	2026-10-29 15:46:47.836446+00
6f0d0280-57dc-4d8f-93b4-a2f20c3bdcf1	Tomate	EPICERIE	kg	INVENTORY	1.000	1000.00	\N	t	\N	2026-10-20 15:03:14.671746+00	2026-10-29 15:46:47.836448+00
7c1d3f7d-dcab-46e0-89b7-a2e0154f4d37	Yet	EPICERIE	pièce	INVENTORY	1.000	1000.00	\N	t	\N	2026-10-20 15:03:14.830837+00	2026-10-29 15:46:47.836451+00
7eb839f2-bc73-4b36-b971-9ed13a5bddd3	Oignon violet	EPICERIE	kg	INVENTORY	2.000	700.00	\N	t	\N	2026-10-20 15:03:14.665307+00	2026-10-29 15:46:47.836453+00
80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	Loss	PROTEINE	pièce	RECIPE	10.000	556.00	\N	t	0,5 poisson par plat observé	2026-10-20 15:03:14.551663+00	2026-10-29 15:46:47.836455+00
888b71eb-baa9-42c4-baa1-fc5ee188b1b1	Épinard	EPICERIE	tas	INVENTORY	1.000	3000.00	\N	t	\N	2026-10-20 15:03:14.74104+00	2026-10-29 15:46:47.83646+00
8ea90fe3-d7e3-4186-a5db-d459dc24d98d	Tomate en pâte	EPICERIE	boîte	INVENTORY	1.000	2250.00	\N	t	4 500 en avril	2026-10-20 15:03:14.675308+00	2026-10-29 15:46:47.836462+00
98fa99bd-50a1-4767-a147-f0a77cdbf912	Poivre	EPICERIE	kg	INVENTORY	2.000	3500.00	\N	t	\N	2026-10-20 15:03:14.766139+00	2026-10-29 15:46:47.836465+00
ab69a04c-8b53-4b94-8620-ad36447574a2	Soumbara	EPICERIE	kg	INVENTORY	1.000	5000.00	\N	t	\N	2026-10-20 15:03:14.81837+00	2026-10-29 15:46:47.83647+00
aeacf1df-c17b-4055-9fd5-204dac99c2fd	Pâte d'arachide	EPICERIE	kg	INVENTORY	2.000	3500.00	\N	t	1 500 en avril	2026-10-20 15:03:14.753572+00	2026-10-29 15:46:47.836472+00
c23a7da5-5358-4a87-bb97-981a779f3e34	Salade	EPICERIE	pièce	INVENTORY	2.000	500.00	\N	t	\N	2026-10-20 15:03:14.723826+00	2026-10-29 15:46:47.836474+00
c2e33d74-f331-415d-bfeb-7c42f66e0296	Moutarde	EPICERIE	pot	INVENTORY	2.000	1400.00	\N	t	\N	2026-10-20 15:03:14.85795+00	2026-10-29 15:46:47.836477+00
c5ce6682-51d4-443f-bb2f-fda4a32b0cb1	Piment	EPICERIE	tas	INVENTORY	2.000	500.00	\N	t	\N	2026-10-20 15:03:14.7693+00	2026-10-29 15:46:47.836479+00
c656b6a5-29d0-4e05-a85a-beb25e986bc4	Oignon	EPICERIE	kg	INVENTORY	2.000	400.00	\N	t	\N	2026-10-20 15:03:14.662034+00	2026-10-29 15:46:47.836482+00
cb9130fc-ac18-4530-acf5-2db2641753f3	Poisson fumé (foufou)	EPICERIE	kg	INVENTORY	2.000	10000.00	\N	t	\N	2026-10-20 15:03:14.785377+00	2026-10-29 15:46:47.836483+00
d1a4136a-5831-4b23-8438-d6f5f15f84fc	Œuf	EPICERIE	pièce	INVENTORY	1.000	84.00	\N	t	\N	2026-10-20 15:03:14.843385+00	2026-10-29 15:46:47.836486+00
d4d263e4-aefa-4d09-bbbc-ba1edc1fb6d9	Vinaigre rouge	EPICERIE	bouteille	INVENTORY	1.000	750.00	\N	t	\N	2026-10-20 15:03:14.864021+00	2026-10-29 15:46:47.836488+00
de94d296-4c58-42ff-920b-691baab6902d	Pistache	EPICERIE	kg	INVENTORY	2.000	3000.00	\N	t	\N	2026-10-20 15:03:14.756914+00	2026-10-29 15:46:47.83649+00
e7c0a607-ae01-4648-86cd-74b12a91e834	Navet	EPICERIE	kg	INVENTORY	1.000	500.00	\N	t	\N	2026-10-20 15:03:14.704592+00	2026-10-29 15:46:47.836495+00
f1b1bd4d-2444-4dc3-a02b-d2e38bd81551	Aromate bouillon	EPICERIE	sachet	INVENTORY	1.000	106.00	\N	t	\N	2026-10-20 15:03:14.896046+00	2026-10-29 15:46:47.862536+00
0e520485-53a3-403a-8dc8-547417bb83e4	Carpe	PROTEINE	pièce	RECIPE	2.000	960.00	\N	t	\N	2026-10-20 15:03:14.546725+00	2026-10-30 11:12:16.141361+00
e4af9701-0d10-404a-9371-a0e7c84ec8f1	Mouton	PROTEINE	kg	RECIPE	8.570	5500.00	\N	t	\N	2026-10-20 15:03:14.45145+00	2026-10-30 11:12:16.141372+00
8353e03f-35a0-44f9-ad7a-5c4336f90725	Poulet	PROTEINE	pièce	RECIPE	7.000	3000.00	\N	t	\N	2026-10-20 15:03:14.506861+00	2026-10-30 11:32:46.345454+00
ebb5f404-2267-4fa1-bd71-dd9e54707294	Bœuf	PROTEINE	kg	RECIPE	7.200	4000.00	\N	t	fournisseur M. Yapi (4 000 F/kg)	2026-10-20 15:03:14.46386+00	2026-10-30 11:32:46.345462+00
a4cbfa56-e146-4cec-b536-34c376c34e28	Sosso	PROTEINE	pièce	RECIPE	3.000	1540.00	\N	t	\N	2026-10-20 15:03:14.531033+00	2026-10-29 16:34:14.341532+00
\.


--
-- Data for Name: stock_items; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.stock_items (id, product_id, quantity, unit, alert_threshold, created_at, updated_at) FROM stdin;
215aec6f-6dbc-40d2-b43e-bbfe2920be7a	26eb12b5-a751-40b0-a6a2-6935fe010159	74	bouteille	10	2026-10-06 10:44:50.965236+00	2026-10-19 14:44:26.383755+00
45343ac2-b842-4fb8-8ce1-a24cb8144dff	6d9aee30-24bf-4df9-a616-ada6c53c4043	69	bouteille	10	2026-10-06 10:44:50.963206+00	2026-10-19 14:53:52.281501+00
4c856c6b-546f-464c-8649-8ebfeb0d7f04	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	87	bouteille	10	2026-10-06 10:44:50.959558+00	2026-10-15 16:41:08.959223+00
\.


--
-- Data for Name: stock_movements; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.stock_movements (id, article_id, type, quantity, quantity_after, unit_cost_xof, business_date, reference_order_id, reference_order_item_id, supplier, reason, user_id, created_at) FROM stdin;
ab77a5f1-76c6-4050-aec2-d48189256305	ebb5f404-2267-4fa1-bd71-dd9e54707294	PURCHASE_IN	10.000	10.000	4000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877139+00
6d718400-7e9f-48d9-b16d-69b491fbd44f	0e520485-53a3-403a-8dc8-547417bb83e4	PURCHASE_IN	10.000	10.000	960.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877162+00
a2620d8e-ca58-4931-878d-a3baa56c53b2	258570a6-aee0-4adb-a7e1-526f56b06506	PURCHASE_IN	10.000	10.000	800.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877171+00
736e5284-728e-42c6-847e-0b8c13bc4bbb	5e5c8e90-160b-4766-abc5-0b06087c6456	PURCHASE_IN	10.000	10.000	500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877178+00
1b91a9f0-0d44-496f-9851-a6daca365d2d	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	PURCHASE_IN	10.000	10.000	556.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877184+00
8aaabd00-c38a-4869-84a8-52e4f6019126	e4af9701-0d10-404a-9371-a0e7c84ec8f1	PURCHASE_IN	10.000	10.000	5500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877191+00
4e5c5e6b-aafa-4959-899c-f0ab95ccf1bf	8353e03f-35a0-44f9-ad7a-5c4336f90725	PURCHASE_IN	10.000	10.000	3000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877197+00
f2598abb-2612-4647-9227-eb2902c8e554	07ee94bb-1c62-4d20-b9e3-9b2aa9132f4a	PURCHASE_IN	10.000	10.000	4000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877202+00
7dfb5c57-f13d-4630-b3ba-f91daaaf4327	a4cbfa56-e146-4cec-b536-34c376c34e28	PURCHASE_IN	10.000	10.000	1540.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877208+00
d89b75d9-94aa-4be1-8783-9c6b6381dade	0d45efe2-2e7f-4d3c-a266-7bb742479fac	PURCHASE_IN	1.000	1.000	750.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877213+00
637c5a4a-4f85-48c0-99ec-cafbf5054a40	d4d263e4-aefa-4d09-bbbc-ba1edc1fb6d9	PURCHASE_IN	1.000	1.000	750.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877219+00
7591e50e-f5ca-4020-a659-74380c2208cf	7c1d3f7d-dcab-46e0-89b7-a2e0154f4d37	PURCHASE_IN	1.000	1.000	1000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877224+00
be701341-c659-40c9-bbbd-b3e717307aa2	888b71eb-baa9-42c4-baa1-fc5ee188b1b1	PURCHASE_IN	1.000	1.000	3000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.87723+00
728d6dde-6010-4703-8a94-abe15cb8e64c	d1a4136a-5831-4b23-8438-d6f5f15f84fc	PURCHASE_IN	1.000	1.000	84.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877236+00
ca934b01-dc60-43f8-aa95-dc3a27a7567f	8ea90fe3-d7e3-4186-a5db-d459dc24d98d	PURCHASE_IN	1.000	1.000	2250.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877241+00
c8075238-fd3d-4d3e-8fb9-8f513e6d49f9	6f0d0280-57dc-4d8f-93b4-a2f20c3bdcf1	PURCHASE_IN	1.000	1.000	1000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877248+00
22388aa5-8314-4bb7-93f6-9dce7a3eae30	ab69a04c-8b53-4b94-8620-ad36447574a2	PURCHASE_IN	1.000	1.000	5000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877253+00
0a292294-1b15-4f97-8d13-5c74848836c6	c23a7da5-5358-4a87-bb97-981a779f3e34	PURCHASE_IN	2.000	2.000	500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.87726+00
3d1869c2-36e2-4a2f-8cb8-a87bd813bb2c	aeacf1df-c17b-4055-9fd5-204dac99c2fd	PURCHASE_IN	2.000	2.000	3500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877267+00
ecd5f20f-a024-466a-a1c8-96733270d720	5deeb776-8c5f-48ec-9ef7-c55f2d51d15d	PURCHASE_IN	2.000	2.000	1000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877273+00
ad876742-3992-4020-b4d2-dabadaa266ea	98fa99bd-50a1-4767-a147-f0a77cdbf912	PURCHASE_IN	2.000	2.000	3500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.87728+00
ee074105-6e15-4f89-a895-e4ae19e541be	cb9130fc-ac18-4530-acf5-2db2641753f3	PURCHASE_IN	2.000	2.000	10000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877286+00
2263b7c5-b0ef-4061-ba38-033a13ec63d1	26290d66-6767-41d8-ba7e-40916c397c90	PURCHASE_IN	2.000	2.000	10000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877292+00
5e94d546-0f3e-4b86-9b57-6a8b9fde6c31	de94d296-4c58-42ff-920b-691baab6902d	PURCHASE_IN	2.000	2.000	3000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877299+00
215a6b89-5d37-4dd0-8b6f-dec2abf383aa	02a19865-af2d-466d-9754-363c10dcda24	PURCHASE_IN	1.000	1.000	1000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877305+00
dd1b11e0-bb40-470b-ac7c-bb5badf585d1	2b2efe1b-6b47-4228-9508-82c43be96592	PURCHASE_IN	1.000	1.000	1000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877311+00
f1f3294a-2065-46ce-99ac-a738c9b70413	2e397e12-f4b0-4c25-96af-63ea19feb790	PURCHASE_IN	2.000	2.000	500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877317+00
b32235d3-e468-4df9-9440-4891b3668144	1cae06ac-04d4-4d22-a52d-487e50268463	PURCHASE_IN	1.000	1.000	2000.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877323+00
f99d74d6-81dd-4e66-a901-c18058f26a62	c5ce6682-51d4-443f-bb2f-fda4a32b0cb1	PURCHASE_IN	2.000	2.000	500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.87733+00
a1341212-8711-4acd-99c5-494fd265c3b1	e7c0a607-ae01-4648-86cd-74b12a91e834	PURCHASE_IN	1.000	1.000	500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877336+00
3a7fbc01-6186-49c9-beff-5a04d0c6768a	7eb839f2-bc73-4b36-b971-9ed13a5bddd3	PURCHASE_IN	2.000	2.000	700.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877356+00
af19521b-c09e-4d37-8c84-16078e1bd8b2	c656b6a5-29d0-4e05-a85a-beb25e986bc4	PURCHASE_IN	2.000	2.000	400.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877363+00
76cf837c-1a9d-4769-ba78-e19891cb0bc0	c2e33d74-f331-415d-bfeb-7c42f66e0296	PURCHASE_IN	2.000	2.000	1400.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877369+00
31a70c17-d1af-4f0d-9348-ef187d0db541	08cb25bf-cdde-4549-9392-f4bf2a9d2909	PURCHASE_IN	2.000	2.000	1500.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877375+00
a4dcb984-28ee-4627-8a7a-e253de070c94	f1b1bd4d-2444-4dc3-a02b-d2e38bd81551	PURCHASE_IN	1.000	1.000	106.00	2026-10-29	\N	\N	\N	Achats marché #2026-10-29	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-29 15:46:47.877381+00
e15f85b1-9b1f-4803-834d-d2c4d15a6b41	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	9.750	3000.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	886a1abb-1324-4132-ab3d-d85de26466f7	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.658219+00
98c1ed45-8d53-481a-849a-aeedaee614ce	0e520485-53a3-403a-8dc8-547417bb83e4	SALE_OUT	-1.000	9.000	960.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	fe43491c-8379-4c80-9019-4980d9ea4046	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.658441+00
eeb72258-2f38-4b50-bbf5-1db207003a17	0e520485-53a3-403a-8dc8-547417bb83e4	SALE_OUT	-1.000	8.000	960.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	b4aa1aa8-bf53-4f86-91b5-c0ae017d86ec	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.65852+00
d88b8acd-fb1a-477b-8257-bbad12d78efb	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	9.800	4000.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	f6516bfe-a30a-4469-a223-235df3a1cf4f	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.658586+00
bf39fea1-38fb-4270-8176-6d387470589b	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	9.600	4000.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	651ad9da-668d-41ca-98bd-fd5c693b36af	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.658652+00
98a50f66-2dc1-4a50-bf94-dd8d5b917dc4	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	9.500	3000.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	c33981ba-c745-446d-99bd-efccdca207da	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.65873+00
1740eec4-ba10-4770-85f9-9b9312ed4227	0e520485-53a3-403a-8dc8-547417bb83e4	SALE_OUT	-1.000	7.000	960.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	4d790f5e-2f4b-4210-b0a6-eefb52b3e773	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.658793+00
3d4d782f-941b-4aa1-b3b1-60e61d28fec9	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	9.400	4000.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	2529e749-aa73-40b1-9478-8e0738879f53	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.658858+00
abdee469-1760-42f9-b4c5-392459119909	a4cbfa56-e146-4cec-b536-34c376c34e28	SALE_OUT	-1.000	9.000	1540.00	2026-10-29	03f1433e-f79b-47f1-923c-55a1b3061ef8	b5f69c09-9d24-4966-82fc-2f95a163bfb1	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:52:41.658918+00
2b092954-7d52-49fd-9e9a-329b9c43be45	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	9.250	3000.00	2026-10-29	4df61102-c27c-4879-8ed2-15b88304cd09	c03f81d8-1777-4c8b-9c91-8c0690d4555a	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:53:45.910116+00
f01343dd-aca5-4419-b09a-277e04903ab0	0e520485-53a3-403a-8dc8-547417bb83e4	SALE_OUT	-1.000	6.000	960.00	2026-10-29	4df61102-c27c-4879-8ed2-15b88304cd09	b033f55d-efa9-4237-bbcc-a0a118c42d13	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:53:45.910303+00
0b56cbd1-d557-429e-885d-055a31ee7547	0e520485-53a3-403a-8dc8-547417bb83e4	SALE_OUT	-1.000	5.000	960.00	2026-10-29	4df61102-c27c-4879-8ed2-15b88304cd09	32cf20d8-7aad-47df-a0bd-9577a68f574c	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:53:45.910399+00
07f36c7a-b6c9-4a4f-8af8-0c056c211438	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	9.200	4000.00	2026-10-29	4df61102-c27c-4879-8ed2-15b88304cd09	b0d9289b-e7f3-44f7-9bc4-2caad7472828	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:53:45.910471+00
5b17a553-32b1-4268-a885-adfc7172303f	e4af9701-0d10-404a-9371-a0e7c84ec8f1	SALE_OUT	-0.286	9.714	5500.00	2026-10-29	4df61102-c27c-4879-8ed2-15b88304cd09	bb293b3e-c92f-49b7-9263-6bab906285f9	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:53:45.910545+00
3ed706b5-6026-4160-ab25-f79f8fe2d8e2	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	9.000	4000.00	2026-10-29	4df61102-c27c-4879-8ed2-15b88304cd09	023cf862-5641-4a2e-b690-00429131a979	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:53:45.910611+00
d442a9ec-88cc-4db6-864b-feae5ae27974	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	9.000	3000.00	2026-10-29	4df61102-c27c-4879-8ed2-15b88304cd09	b3526943-6b8d-4a08-9516-18f61ad84c12	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:53:45.910677+00
fb13b9a6-6cc0-448b-b5f7-8f33bf260f1b	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	8.800	4000.00	2026-10-29	4df61102-c27c-4879-8ed2-15b88304cd09	88811e0e-bea9-4939-a16d-7456e20b1d2e	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 15:53:45.910743+00
72c817bf-6fad-48fe-9531-ee52686cc1bf	a4cbfa56-e146-4cec-b536-34c376c34e28	SALE_OUT	-1.000	8.000	1540.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	1b705b20-098e-4504-8b97-1b53a198a141	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.786127+00
08135163-9870-4074-a35a-f86f4245bc64	a4cbfa56-e146-4cec-b536-34c376c34e28	SALE_OUT	-1.000	7.000	1540.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	1b32cc23-9ad8-4a45-97c9-fb91c0d24abb	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.787646+00
58450fbe-e2db-4450-af8a-dde3d646b970	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	8.750	3000.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	ddc6864b-3904-41f3-9f3a-b791af71aedc	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.787836+00
2f8d99a9-fffe-4de6-a361-eeca66bb85bc	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	8.600	4000.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	34a0bc05-7144-4cf4-b542-2edb6a271273	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.787948+00
734d2363-928f-4b6a-b7c8-e9c49d7edbfb	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	8.400	4000.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	cf4f9468-9d80-4cd0-a28f-f3ea46ac8ff2	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.788053+00
2bf36b3c-b0a1-4f2d-b371-dff9c469889a	e4af9701-0d10-404a-9371-a0e7c84ec8f1	SALE_OUT	-0.286	9.428	5500.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	db889a3d-91e0-478f-ba4e-e266bcdccd46	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.788165+00
549e50bf-5dad-4c33-8b01-5c402488cae9	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	8.500	3000.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	8e61150a-5664-470a-8ae3-ee2f8a2bdb4d	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.788251+00
2cf4b7fc-bec3-4c66-ac22-1f11fc0112be	0e520485-53a3-403a-8dc8-547417bb83e4	SALE_OUT	-1.000	4.000	960.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	3ff47e3f-82e6-45f4-8ae4-a4e854c07bcc	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.788376+00
4541d8ab-d19a-4d71-ae1f-369fe3044d41	e4af9701-0d10-404a-9371-a0e7c84ec8f1	SALE_OUT	-0.286	9.142	5500.00	2026-10-29	dcedcffe-336a-4484-988f-b28e1a2e7ba0	96301ae0-6da5-4801-81e0-e95b2025e5c6	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:33:55.788479+00
9f9b1e4a-1d31-44d3-b726-ac85b25c3dd8	a4cbfa56-e146-4cec-b536-34c376c34e28	SALE_OUT	-1.000	6.000	1540.00	2026-10-29	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	52cacaa5-7d53-41fe-8e84-616f049e5043	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:34:14.332759+00
15a8ad79-0789-4e51-953c-d628ad0ea4e5	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	8.200	4000.00	2026-10-29	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	5884e7fb-f015-4316-8833-f3da0c3ddeed	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:34:14.332938+00
b8479173-c327-4982-9a94-e900439eebd9	a4cbfa56-e146-4cec-b536-34c376c34e28	SALE_OUT	-1.000	5.000	1540.00	2026-10-29	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	53813ee6-0602-4f66-88d0-bb3079b78275	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:34:14.333027+00
e3908bd9-2db3-4ff0-a9f2-d19eebfd9ce3	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	8.250	3000.00	2026-10-29	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	10da25f8-2495-4165-b908-37c7fd9f821b	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:34:14.333109+00
6fda199d-047b-4fe7-ac68-4bcd50d710d3	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	8.000	3000.00	2026-10-29	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	6b6248ae-cd37-4b18-a89b-f73c403b9622	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:34:14.333168+00
51e59396-0c70-4779-a049-d41e8bdc7b7f	a4cbfa56-e146-4cec-b536-34c376c34e28	SALE_OUT	-1.000	4.000	1540.00	2026-10-29	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	a36043cf-1af4-4f12-a5d3-28386af12cdc	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:34:14.333227+00
09341703-2747-433f-a9c8-e7db0e4a7fcc	a4cbfa56-e146-4cec-b536-34c376c34e28	SALE_OUT	-1.000	3.000	1540.00	2026-10-29	786345a5-e9b2-4ac6-89f4-4397ba8b4fa7	44233049-ad0f-420f-9fc7-c94a58dba425	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-29 16:34:14.333303+00
94e43a18-be6d-4352-896f-3ba612b4298c	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	8.000	4000.00	2026-10-30	05ad026a-7ca3-47fe-a3c6-93ca6b508870	ea48c73b-7797-4838-9f2f-ecc20058df81	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:05:12.043568+00
9034cc72-792d-491d-8eef-d2516ffe30ff	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	7.800	4000.00	2026-10-30	1b4709eb-7431-4782-8ff3-bd821ed4b2ec	079270e7-fdd9-47c8-ae6e-580f83a4d0ed	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:10:16.639367+00
ff82567f-90f9-4016-9b33-efdf2c96367e	0e520485-53a3-403a-8dc8-547417bb83e4	SALE_OUT	-1.000	3.000	960.00	2026-10-30	c9bc61b4-ad71-4a9f-93c6-918d772fb438	ae8c1b03-97ca-4fca-b599-b62195f3cd51	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:16.130276+00
8387ba9a-0669-432f-a99e-386520be9f42	e4af9701-0d10-404a-9371-a0e7c84ec8f1	SALE_OUT	-0.286	8.856	5500.00	2026-10-30	c9bc61b4-ad71-4a9f-93c6-918d772fb438	70224647-ff1a-405c-844c-62c1b1d3130b	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:16.130488+00
0de6f42c-5eb3-4004-bee4-b88bfc832f04	0e520485-53a3-403a-8dc8-547417bb83e4	SALE_OUT	-1.000	2.000	960.00	2026-10-30	c9bc61b4-ad71-4a9f-93c6-918d772fb438	a585b556-87e4-4302-8160-a2a342eb99d4	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:16.13054+00
3a49b7f0-8c4d-4f86-82b4-65aa54a26fa2	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	7.750	3000.00	2026-10-30	c9bc61b4-ad71-4a9f-93c6-918d772fb438	6099bd33-f0d3-42ed-ad6b-c13d3f74e1fe	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:16.130587+00
197c7443-adea-4ac1-9c1a-e28f50dc802b	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	7.600	4000.00	2026-10-30	c9bc61b4-ad71-4a9f-93c6-918d772fb438	de335dd4-55c1-44a5-9a9e-569dcec3f62f	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:16.130626+00
67968d92-b3fa-4dcd-b8cb-0711e82f814d	e4af9701-0d10-404a-9371-a0e7c84ec8f1	SALE_OUT	-0.286	8.570	5500.00	2026-10-30	c9bc61b4-ad71-4a9f-93c6-918d772fb438	d62d4f89-0e16-482e-ae46-95334f9006c5	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:16.130664+00
b8d8ecab-4b99-4e16-8b7a-abcbaa474728	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	7.500	3000.00	2026-10-30	c9bc61b4-ad71-4a9f-93c6-918d772fb438	30da91b1-bd3a-4ffe-9a86-f0ffb4e157b8	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:12:16.130697+00
e89b3681-9d40-441c-a8a6-8a33afdddca9	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	7.400	4000.00	2026-10-30	ff8f5b34-95af-4d39-90dd-2308a7d41876	8cc4a9e5-1b4f-4342-a8a2-1d1bb8419de8	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:32:46.335772+00
d0ae6c28-ef01-4cad-8531-8fb1d8b750db	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	7.250	3000.00	2026-10-30	ff8f5b34-95af-4d39-90dd-2308a7d41876	0289f245-63b2-4ce2-8774-924e3a3d5727	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:32:46.335938+00
eb2d767a-f7f3-4673-8800-25a34c487811	ebb5f404-2267-4fa1-bd71-dd9e54707294	SALE_OUT	-0.200	7.200	4000.00	2026-10-30	ff8f5b34-95af-4d39-90dd-2308a7d41876	81f15313-d890-43b7-8a5f-2d6abacf0299	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:32:46.335997+00
10243b4a-db55-49ec-a447-c8544bb4ff22	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	7.000	3000.00	2026-10-30	ff8f5b34-95af-4d39-90dd-2308a7d41876	080cefe1-d22d-4e91-984b-b20f3dcc7992	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-30 11:32:46.336048+00
\.


--
-- Data for Name: superettes; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.superettes (id, code, nom, adresse, ville, actif, created_at) FROM stdin;
284	SUP-01	Superette Principale	Centre-ville, Av. de la Paix	Abidjan	t	2026-09-01 15:05:58.315391+00
377	SORBONNE	Yopougon Sorbonne	Rue des Princes, Yopougon	Abidjan	t	2026-09-02 11:02:35.55668+00
378	ANGRE	Cocody Angré 8ème Tranche	Boulevard Latrille	Abidjan	t	2026-09-02 11:02:35.55668+00
379	MARCORY	Marcory Résidentiel	Avenue CI	Abidjan	t	2026-09-02 11:02:35.55668+00
\.


--
-- Data for Name: suppliers; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.suppliers (id, name, contact_name, phone, email, address, notes, is_active, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.users (id, full_name, pin_hash, role, is_active, failed_attempts, locked_until, last_login_at, created_at, updated_at) FROM stdin;
a3e01053-c2ad-4631-910a-0eb48345e5b1	Économe Marché	$argon2id$v=19$m=65536,t=3,p=4$Xz1gQHDZuL6WVpHFWzJ9oA$ir489NrBIBaNracEmQFfmuY+7wfjSAx1sFY3rBSos9U	ECONOME	t	0	\N	2026-10-29 15:47:04.77468+00	2026-10-22 10:56:08.7902+00	2026-10-29 15:47:04.791457+00
5d9ffecd-87a5-47ff-80c4-f9c1c457293c	Digui Thio	$argon2id$v=19$m=65536,t=3,p=4$Md97/XbvbaCwLFqYZ1daDg$UKqWC3skjutOFFNxDGntbhuqF2Sxr/sAjLisKi1LCfQ	CAISSIER	t	0	\N	2026-10-30 11:32:15.42954+00	2026-10-03 16:12:32.820964+00	2026-10-30 11:32:15.437551+00
4b5224bf-057a-4654-b13e-0e65ff403161	Administrateur	$argon2id$v=19$m=65536,t=3,p=4$GqJWVRaBv6eGu1kK+Ow9lQ$ZEtbcvnGxvrCqOuCC7nIXxyvb3Zq3tGfMms1mHsJeH0	ADMIN	t	0	\N	2026-10-30 11:33:00.12359+00	2026-10-03 16:12:32.997768+00	2026-10-30 11:33:00.131643+00
695652d7-7ab3-4b5d-a001-d4096cb849a0	Responsable Restaurant	$argon2id$v=19$m=65536,t=3,p=4$frm0zYKSbZ10S7eGqRBqxQ$xchoZhabdN6xP/rEAizxamDgNS05L3K8QfC15xqSBfA	RESPONSABLE	t	0	\N	2026-10-29 14:00:09.186433+00	2026-10-03 16:12:32.906777+00	2026-10-29 14:00:09.202156+00
\.


--
-- Data for Name: utilisateurs; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.utilisateurs (id, matricule, nom_complet, email, telephone, mot_de_passe_hash, role, superette_id, actif, created_at) FROM stdin;
2419	RESP001	Mamadou Koné (Resp. Sorbonne)	resp.sorbonne@superette.ci	+225 0708091011	$2b$12$izYt1DHLIyjXbQVgUfQOruFo.Y5lQs20SHJsx5A.UygrGZSA8jKTS	responsable	377	t	2026-09-28 10:54:44.09963+00
432	GEST001	Adjoua Kouamé (RAF)	admin@superette.ci	+225 0708091011	$2b$12$9/CyChe6HNdJEzAdwR.mE.4SsXTAW5938IXj2WgtZi8RNCWTHyT8a	admin	\N	t	2026-09-02 11:02:35.55668+00
2340	GEST002	Administrateur	main.js0308@gmail.com	\N	$2b$12$n0tlKXIQ99t2gA48FQ/W/.NqL1ATkCNQS4DopxH8sYQmU/KvvzFWW	admin	\N	t	2026-09-18 17:22:07.77842+00
316	CAIS01	Kouamé Aya	aya.kouame@caisse.ci	\N	$2b$12$e.5gtoTTtmOD1nLIzof29.2K4Bn7aQKuPjYMGSSL45rplMMvDirCS	caissier	284	f	2026-09-01 15:05:58.315391+00
315	ADMIN01	Administrateur Système	admin@caisse.ci	+225 0700000000	$2b$12$1JktCj1VQSAOnFUR/ZF4UOpM0k5IW8TquY4EDUvBjxh4q7QEt39Qa	admin	\N	t	2026-09-01 15:05:58.315391+00
433	CAIS001	Awa Bakayoko (Caisse Sorbonne)	caissier@superette.ci	+225 0102030405	$2b$12$SGCf1jf5m3nlY.ZsmcrcV.smIEnoKf8LQcBfp8qVp3Sx1xYCo9xfW	caissier	377	t	2026-09-02 11:02:35.55668+00
2420	RESP002	Jean-Marc Yao (Resp. Angré)	resp.angre@superette.ci	+225 0708091012	$2b$12$mLEctJIhycdhWHAQGYdWrejaZBiCsoGcxwk4efNBPe4IDYZnacfYG	responsable	378	t	2026-09-28 10:54:44.09963+00
2421	CAIS002	Kouamé Aya (Caisse Angré)	caissier.angre@superette.ci	+225 0102030406	$2b$12$z2/O1.VW9ErPodBvjOfxH.y.oorjJWzMbJEMcBkiHhyP/MM3dS.iG	caissier	378	t	2026-09-28 10:54:44.09963+00
\.


--
-- Name: audit_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.audit_log_id_seq', 4803, true);


--
-- Name: autorisations_depense_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.autorisations_depense_id_seq', 519, true);


--
-- Name: billetage_comptage_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.billetage_comptage_id_seq', 835, true);


--
-- Name: cahier_tresorerie_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.cahier_tresorerie_id_seq', 702, true);


--
-- Name: caisse_journees_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.caisse_journees_id_seq', 1958, true);


--
-- Name: categories_depense_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.categories_depense_id_seq', 78, true);


--
-- Name: denominations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.denominations_id_seq', 25, true);


--
-- Name: fournisseurs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.fournisseurs_id_seq', 6, true);


--
-- Name: justificatifs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.justificatifs_id_seq', 134, true);


--
-- Name: operations_decaissement_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.operations_decaissement_id_seq', 654, true);


--
-- Name: operations_encaissement_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.operations_encaissement_id_seq', 576, true);


--
-- Name: superettes_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.superettes_id_seq', 2608, true);


--
-- Name: utilisateurs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: caisse_user
--

SELECT pg_catalog.setval('public.utilisateurs_id_seq', 3137, true);


--
-- Name: alembic_version alembic_version_pkc; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.alembic_version
    ADD CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: autorisations_depense autorisations_depense_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.autorisations_depense
    ADD CONSTRAINT autorisations_depense_pkey PRIMARY KEY (id);


--
-- Name: bank_deposits bank_deposits_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.bank_deposits
    ADD CONSTRAINT bank_deposits_pkey PRIMARY KEY (id);


--
-- Name: billetage_comptage billetage_comptage_caisse_journee_id_denomination_id_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.billetage_comptage
    ADD CONSTRAINT billetage_comptage_caisse_journee_id_denomination_id_key UNIQUE (caisse_journee_id, denomination_id);


--
-- Name: billetage_comptage billetage_comptage_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.billetage_comptage
    ADD CONSTRAINT billetage_comptage_pkey PRIMARY KEY (id);


--
-- Name: cahier_tresorerie cahier_tresorerie_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cahier_tresorerie
    ADD CONSTRAINT cahier_tresorerie_pkey PRIMARY KEY (id);


--
-- Name: caisse_journees caisse_journees_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.caisse_journees
    ADD CONSTRAINT caisse_journees_pkey PRIMARY KEY (id);


--
-- Name: caisse_journees caisse_journees_superette_id_date_operation_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.caisse_journees
    ADD CONSTRAINT caisse_journees_superette_id_date_operation_key UNIQUE (superette_id, date_operation);


--
-- Name: cash_expenses cash_expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_expenses
    ADD CONSTRAINT cash_expenses_pkey PRIMARY KEY (id);


--
-- Name: cash_movements cash_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_movements
    ADD CONSTRAINT cash_movements_pkey PRIMARY KEY (id);


--
-- Name: cash_registers cash_registers_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_registers
    ADD CONSTRAINT cash_registers_pkey PRIMARY KEY (id);


--
-- Name: cash_sessions cash_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_sessions
    ADD CONSTRAINT cash_sessions_pkey PRIMARY KEY (id);


--
-- Name: categories_depense categories_depense_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.categories_depense
    ADD CONSTRAINT categories_depense_pkey PRIMARY KEY (id);


--
-- Name: categories categories_name_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_name_key UNIQUE (name);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: daily_preparations daily_preparations_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.daily_preparations
    ADD CONSTRAINT daily_preparations_pkey PRIMARY KEY (id);


--
-- Name: denominations denominations_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.denominations
    ADD CONSTRAINT denominations_pkey PRIMARY KEY (id);


--
-- Name: denominations denominations_valeur_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.denominations
    ADD CONSTRAINT denominations_valeur_key UNIQUE (valeur);


--
-- Name: establishment_settings establishment_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.establishment_settings
    ADD CONSTRAINT establishment_settings_pkey PRIMARY KEY (id);


--
-- Name: fne_documents fne_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.fne_documents
    ADD CONSTRAINT fne_documents_pkey PRIMARY KEY (id);


--
-- Name: fournisseurs fournisseurs_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.fournisseurs
    ADD CONSTRAINT fournisseurs_pkey PRIMARY KEY (id);


--
-- Name: idempotency_records idempotency_records_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.idempotency_records
    ADD CONSTRAINT idempotency_records_pkey PRIMARY KEY (key);


--
-- Name: justificatifs justificatifs_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.justificatifs
    ADD CONSTRAINT justificatifs_pkey PRIMARY KEY (id);


--
-- Name: market_purchase_items market_purchase_items_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.market_purchase_items
    ADD CONSTRAINT market_purchase_items_pkey PRIMARY KEY (id);


--
-- Name: market_purchase_lists market_purchase_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.market_purchase_lists
    ADD CONSTRAINT market_purchase_lists_pkey PRIMARY KEY (id);


--
-- Name: operations_decaissement operations_decaissement_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_decaissement
    ADD CONSTRAINT operations_decaissement_pkey PRIMARY KEY (id);


--
-- Name: operations_encaissement operations_encaissement_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_encaissement
    ADD CONSTRAINT operations_encaissement_pkey PRIMARY KEY (id);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- Name: orders orders_order_number_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_order_number_key UNIQUE (order_number);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: outbox_events outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT outbox_events_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: print_jobs print_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.print_jobs
    ADD CONSTRAINT print_jobs_pkey PRIMARY KEY (id);


--
-- Name: print_terminals print_terminals_name_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.print_terminals
    ADD CONSTRAINT print_terminals_name_key UNIQUE (name);


--
-- Name: print_terminals print_terminals_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.print_terminals
    ADD CONSTRAINT print_terminals_pkey PRIMARY KEY (id);


--
-- Name: print_terminals print_terminals_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.print_terminals
    ADD CONSTRAINT print_terminals_token_hash_key UNIQUE (token_hash);


--
-- Name: product_components product_components_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.product_components
    ADD CONSTRAINT product_components_pkey PRIMARY KEY (id);


--
-- Name: product_price_history product_price_history_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.product_price_history
    ADD CONSTRAINT product_price_history_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: purchase_invoices purchase_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_invoices
    ADD CONSTRAINT purchase_invoices_pkey PRIMARY KEY (id);


--
-- Name: purchase_items purchase_items_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_items
    ADD CONSTRAINT purchase_items_pkey PRIMARY KEY (id);


--
-- Name: purchase_request_lines purchase_request_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_request_lines
    ADD CONSTRAINT purchase_request_lines_pkey PRIMARY KEY (id);


--
-- Name: purchase_requests purchase_requests_number_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_requests
    ADD CONSTRAINT purchase_requests_number_key UNIQUE (number);


--
-- Name: purchase_requests purchase_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_requests
    ADD CONSTRAINT purchase_requests_pkey PRIMARY KEY (id);


--
-- Name: raw_material_movements raw_material_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.raw_material_movements
    ADD CONSTRAINT raw_material_movements_pkey PRIMARY KEY (id);


--
-- Name: raw_materials raw_materials_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.raw_materials
    ADD CONSTRAINT raw_materials_pkey PRIMARY KEY (id);


--
-- Name: restaurant_tables restaurant_tables_label_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.restaurant_tables
    ADD CONSTRAINT restaurant_tables_label_key UNIQUE (label);


--
-- Name: restaurant_tables restaurant_tables_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.restaurant_tables
    ADD CONSTRAINT restaurant_tables_pkey PRIMARY KEY (id);


--
-- Name: sequence_counters sequence_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.sequence_counters
    ADD CONSTRAINT sequence_counters_pkey PRIMARY KEY (key);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (key);


--
-- Name: stock_articles stock_articles_name_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_articles
    ADD CONSTRAINT stock_articles_name_key UNIQUE (name);


--
-- Name: stock_articles stock_articles_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_articles
    ADD CONSTRAINT stock_articles_pkey PRIMARY KEY (id);


--
-- Name: stock_items stock_items_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_items
    ADD CONSTRAINT stock_items_pkey PRIMARY KEY (id);


--
-- Name: stock_items stock_items_product_id_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_items
    ADD CONSTRAINT stock_items_product_id_key UNIQUE (product_id);


--
-- Name: stock_movements stock_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (id);


--
-- Name: superettes superettes_code_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.superettes
    ADD CONSTRAINT superettes_code_key UNIQUE (code);


--
-- Name: superettes superettes_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.superettes
    ADD CONSTRAINT superettes_pkey PRIMARY KEY (id);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id);


--
-- Name: daily_preparations uq_daily_prep_date_article; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.daily_preparations
    ADD CONSTRAINT uq_daily_prep_date_article UNIQUE (business_date, article_id);


--
-- Name: operations_decaissement uq_decaissement_autorisation_id; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_decaissement
    ADD CONSTRAINT uq_decaissement_autorisation_id UNIQUE (autorisation_id);


--
-- Name: product_components uq_product_components_product_article; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.product_components
    ADD CONSTRAINT uq_product_components_product_article UNIQUE (product_id, article_id);


--
-- Name: purchase_request_lines uq_purchase_request_lines_article; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_request_lines
    ADD CONSTRAINT uq_purchase_request_lines_article UNIQUE (request_id, article_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: utilisateurs utilisateurs_email_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.utilisateurs
    ADD CONSTRAINT utilisateurs_email_key UNIQUE (email);


--
-- Name: utilisateurs utilisateurs_matricule_key; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.utilisateurs
    ADD CONSTRAINT utilisateurs_matricule_key UNIQUE (matricule);


--
-- Name: utilisateurs utilisateurs_pkey; Type: CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.utilisateurs
    ADD CONSTRAINT utilisateurs_pkey PRIMARY KEY (id);


--
-- Name: idx_caisse_journees_superette_date; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX idx_caisse_journees_superette_date ON public.caisse_journees USING btree (superette_id, date_operation);


--
-- Name: idx_decaissement_journee; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX idx_decaissement_journee ON public.operations_decaissement USING btree (caisse_journee_id);


--
-- Name: idx_encaissement_journee; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX idx_encaissement_journee ON public.operations_encaissement USING btree (caisse_journee_id);


--
-- Name: idx_tresorerie_superette_date; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX idx_tresorerie_superette_date ON public.cahier_tresorerie USING btree (superette_id, date_mouvement);


--
-- Name: ix_audit_log_date_action; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_audit_log_date_action ON public.audit_log USING btree (date_action);


--
-- Name: ix_audit_log_ligne_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_audit_log_ligne_id ON public.audit_log USING btree (ligne_id);


--
-- Name: ix_audit_log_table_cible; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_audit_log_table_cible ON public.audit_log USING btree (table_cible);


--
-- Name: ix_audit_log_utilisateur_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_audit_log_utilisateur_id ON public.audit_log USING btree (utilisateur_id);


--
-- Name: ix_bank_deposits_business_date; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_bank_deposits_business_date ON public.bank_deposits USING btree (business_date);


--
-- Name: ix_cash_expenses_business_date; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_cash_expenses_business_date ON public.cash_expenses USING btree (business_date);


--
-- Name: ix_cash_expenses_cash_session_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_cash_expenses_cash_session_id ON public.cash_expenses USING btree (cash_session_id);


--
-- Name: ix_customers_name; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_customers_name ON public.customers USING btree (name);


--
-- Name: ix_customers_ncc; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_customers_ncc ON public.customers USING btree (ncc);


--
-- Name: ix_customers_phone; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_customers_phone ON public.customers USING btree (phone);


--
-- Name: ix_daily_preparations_article_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_daily_preparations_article_id ON public.daily_preparations USING btree (article_id);


--
-- Name: ix_daily_preparations_business_date; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_daily_preparations_business_date ON public.daily_preparations USING btree (business_date);


--
-- Name: ix_fne_documents_customer_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_fne_documents_customer_id ON public.fne_documents USING btree (customer_id);


--
-- Name: ix_fne_documents_external_number; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_fne_documents_external_number ON public.fne_documents USING btree (external_number);


--
-- Name: ix_fne_documents_invoice_number; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE UNIQUE INDEX ix_fne_documents_invoice_number ON public.fne_documents USING btree (invoice_number);


--
-- Name: ix_fne_documents_order_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_fne_documents_order_id ON public.fne_documents USING btree (order_id);


--
-- Name: ix_fne_documents_parent_document_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_fne_documents_parent_document_id ON public.fne_documents USING btree (parent_document_id);


--
-- Name: ix_fne_documents_status; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_fne_documents_status ON public.fne_documents USING btree (status);


--
-- Name: ix_justificatifs_operation_decaissement_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_justificatifs_operation_decaissement_id ON public.justificatifs USING btree (operation_decaissement_id);


--
-- Name: ix_market_purchase_items_article_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_market_purchase_items_article_id ON public.market_purchase_items USING btree (article_id);


--
-- Name: ix_market_purchase_items_purchase_list_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_market_purchase_items_purchase_list_id ON public.market_purchase_items USING btree (purchase_list_id);


--
-- Name: ix_market_purchase_lists_business_date; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_market_purchase_lists_business_date ON public.market_purchase_lists USING btree (business_date);


--
-- Name: ix_market_purchase_lists_status; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_market_purchase_lists_status ON public.market_purchase_lists USING btree (status);


--
-- Name: ix_orders_active_table; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_orders_active_table ON public.orders USING btree (table_id) WHERE ((status)::text = ANY ((ARRAY['OPEN'::character varying, 'PARTIALLY_PAID'::character varying])::text[]));


--
-- Name: ix_outbox_events_aggregate_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_outbox_events_aggregate_id ON public.outbox_events USING btree (aggregate_id);


--
-- Name: ix_outbox_events_event_type; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_outbox_events_event_type ON public.outbox_events USING btree (event_type);


--
-- Name: ix_outbox_events_next_retry_at; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_outbox_events_next_retry_at ON public.outbox_events USING btree (next_retry_at);


--
-- Name: ix_outbox_events_status; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_outbox_events_status ON public.outbox_events USING btree (status);


--
-- Name: ix_product_components_article_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_product_components_article_id ON public.product_components USING btree (article_id);


--
-- Name: ix_product_components_product_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_product_components_product_id ON public.product_components USING btree (product_id);


--
-- Name: ix_purchase_invoices_delivery_date; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_invoices_delivery_date ON public.purchase_invoices USING btree (delivery_date);


--
-- Name: ix_purchase_invoices_invoice_number; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_invoices_invoice_number ON public.purchase_invoices USING btree (invoice_number);


--
-- Name: ix_purchase_invoices_received_by_user_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_invoices_received_by_user_id ON public.purchase_invoices USING btree (received_by_user_id);


--
-- Name: ix_purchase_invoices_supplier_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_invoices_supplier_id ON public.purchase_invoices USING btree (supplier_id);


--
-- Name: ix_purchase_items_purchase_invoice_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_items_purchase_invoice_id ON public.purchase_items USING btree (purchase_invoice_id);


--
-- Name: ix_purchase_items_raw_material_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_items_raw_material_id ON public.purchase_items USING btree (raw_material_id);


--
-- Name: ix_purchase_request_lines_article_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_request_lines_article_id ON public.purchase_request_lines USING btree (article_id);


--
-- Name: ix_purchase_request_lines_request_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_request_lines_request_id ON public.purchase_request_lines USING btree (request_id);


--
-- Name: ix_purchase_requests_requested_by_user_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_requests_requested_by_user_id ON public.purchase_requests USING btree (requested_by_user_id);


--
-- Name: ix_purchase_requests_status; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_purchase_requests_status ON public.purchase_requests USING btree (status);


--
-- Name: ix_raw_material_movements_raw_material_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_raw_material_movements_raw_material_id ON public.raw_material_movements USING btree (raw_material_id);


--
-- Name: ix_raw_material_movements_user_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_raw_material_movements_user_id ON public.raw_material_movements USING btree (user_id);


--
-- Name: ix_raw_materials_category; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_raw_materials_category ON public.raw_materials USING btree (category);


--
-- Name: ix_raw_materials_name; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE UNIQUE INDEX ix_raw_materials_name ON public.raw_materials USING btree (name);


--
-- Name: ix_stock_movements_article_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_stock_movements_article_id ON public.stock_movements USING btree (article_id);


--
-- Name: ix_stock_movements_business_date; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_stock_movements_business_date ON public.stock_movements USING btree (business_date);


--
-- Name: ix_stock_movements_reference_order_id; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE INDEX ix_stock_movements_reference_order_id ON public.stock_movements USING btree (reference_order_id);


--
-- Name: ix_suppliers_name; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE UNIQUE INDEX ix_suppliers_name ON public.suppliers USING btree (name);


--
-- Name: uq_cash_register_single_open_session; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE UNIQUE INDEX uq_cash_register_single_open_session ON public.cash_sessions USING btree (cash_register_id) WHERE ((status)::text <> 'CLOSED'::text);


--
-- Name: uq_fne_documents_one_sale_per_order; Type: INDEX; Schema: public; Owner: caisse_user
--

CREATE UNIQUE INDEX uq_fne_documents_one_sale_per_order ON public.fne_documents USING btree (order_id) WHERE ((type)::text = 'FNE'::text);


--
-- Name: caisse_journees trg_alimenter_tresorerie; Type: TRIGGER; Schema: public; Owner: caisse_user
--

CREATE TRIGGER trg_alimenter_tresorerie AFTER UPDATE ON public.caisse_journees FOR EACH ROW EXECUTE FUNCTION public.alimenter_cahier_tresorerie();


--
-- Name: billetage_comptage trg_billetage_maj; Type: TRIGGER; Schema: public; Owner: caisse_user
--

CREATE TRIGGER trg_billetage_maj AFTER INSERT OR DELETE OR UPDATE ON public.billetage_comptage FOR EACH ROW EXECUTE FUNCTION public.trg_recalculer_totaux();


--
-- Name: operations_decaissement trg_decaissement_maj; Type: TRIGGER; Schema: public; Owner: caisse_user
--

CREATE TRIGGER trg_decaissement_maj AFTER INSERT OR DELETE OR UPDATE ON public.operations_decaissement FOR EACH ROW EXECUTE FUNCTION public.trg_recalculer_totaux();


--
-- Name: operations_encaissement trg_encaissement_maj; Type: TRIGGER; Schema: public; Owner: caisse_user
--

CREATE TRIGGER trg_encaissement_maj AFTER INSERT OR DELETE OR UPDATE ON public.operations_encaissement FOR EACH ROW EXECUTE FUNCTION public.trg_recalculer_totaux();


--
-- Name: billetage_comptage trg_lock_billetage; Type: TRIGGER; Schema: public; Owner: caisse_user
--

CREATE TRIGGER trg_lock_billetage BEFORE INSERT OR DELETE OR UPDATE ON public.billetage_comptage FOR EACH ROW EXECUTE FUNCTION public.empecher_modif_journee_cloturee();


--
-- Name: operations_decaissement trg_lock_decaissement; Type: TRIGGER; Schema: public; Owner: caisse_user
--

CREATE TRIGGER trg_lock_decaissement BEFORE INSERT OR DELETE OR UPDATE ON public.operations_decaissement FOR EACH ROW EXECUTE FUNCTION public.empecher_modif_journee_cloturee();


--
-- Name: operations_encaissement trg_lock_encaissement; Type: TRIGGER; Schema: public; Owner: caisse_user
--

CREATE TRIGGER trg_lock_encaissement BEFORE INSERT OR DELETE OR UPDATE ON public.operations_encaissement FOR EACH ROW EXECUTE FUNCTION public.empecher_modif_journee_cloturee();


--
-- Name: audit_log audit_log_utilisateur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_utilisateur_id_fkey FOREIGN KEY (utilisateur_id) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: audit_logs audit_logs_acting_as_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_acting_as_user_id_fkey FOREIGN KEY (acting_as_user_id) REFERENCES public.users(id);


--
-- Name: audit_logs audit_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: autorisations_depense autorisations_depense_approuve_par_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.autorisations_depense
    ADD CONSTRAINT autorisations_depense_approuve_par_fkey FOREIGN KEY (approuve_par) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: autorisations_depense autorisations_depense_caisse_journee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.autorisations_depense
    ADD CONSTRAINT autorisations_depense_caisse_journee_id_fkey FOREIGN KEY (caisse_journee_id) REFERENCES public.caisse_journees(id) ON DELETE SET NULL;


--
-- Name: bank_deposits bank_deposits_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.bank_deposits
    ADD CONSTRAINT bank_deposits_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: billetage_comptage billetage_comptage_caisse_journee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.billetage_comptage
    ADD CONSTRAINT billetage_comptage_caisse_journee_id_fkey FOREIGN KEY (caisse_journee_id) REFERENCES public.caisse_journees(id) ON DELETE CASCADE;


--
-- Name: billetage_comptage billetage_comptage_denomination_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.billetage_comptage
    ADD CONSTRAINT billetage_comptage_denomination_id_fkey FOREIGN KEY (denomination_id) REFERENCES public.denominations(id) ON DELETE RESTRICT;


--
-- Name: cahier_tresorerie cahier_tresorerie_caisse_journee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cahier_tresorerie
    ADD CONSTRAINT cahier_tresorerie_caisse_journee_id_fkey FOREIGN KEY (caisse_journee_id) REFERENCES public.caisse_journees(id) ON DELETE SET NULL;


--
-- Name: cahier_tresorerie cahier_tresorerie_saisi_par_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cahier_tresorerie
    ADD CONSTRAINT cahier_tresorerie_saisi_par_fkey FOREIGN KEY (saisi_par) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: cahier_tresorerie cahier_tresorerie_superette_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cahier_tresorerie
    ADD CONSTRAINT cahier_tresorerie_superette_id_fkey FOREIGN KEY (superette_id) REFERENCES public.superettes(id) ON DELETE RESTRICT;


--
-- Name: caisse_journees caisse_journees_cloturee_par_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.caisse_journees
    ADD CONSTRAINT caisse_journees_cloturee_par_fkey FOREIGN KEY (cloturee_par) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: caisse_journees caisse_journees_ouverte_par_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.caisse_journees
    ADD CONSTRAINT caisse_journees_ouverte_par_fkey FOREIGN KEY (ouverte_par) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: caisse_journees caisse_journees_superette_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.caisse_journees
    ADD CONSTRAINT caisse_journees_superette_id_fkey FOREIGN KEY (superette_id) REFERENCES public.superettes(id) ON DELETE RESTRICT;


--
-- Name: caisse_journees caisse_journees_validee_par_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.caisse_journees
    ADD CONSTRAINT caisse_journees_validee_par_fkey FOREIGN KEY (validee_par) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: cash_expenses cash_expenses_cash_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_expenses
    ADD CONSTRAINT cash_expenses_cash_session_id_fkey FOREIGN KEY (cash_session_id) REFERENCES public.cash_sessions(id);


--
-- Name: cash_expenses cash_expenses_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_expenses
    ADD CONSTRAINT cash_expenses_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: cash_movements cash_movements_cash_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_movements
    ADD CONSTRAINT cash_movements_cash_session_id_fkey FOREIGN KEY (cash_session_id) REFERENCES public.cash_sessions(id);


--
-- Name: cash_movements cash_movements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_movements
    ADD CONSTRAINT cash_movements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: cash_sessions cash_sessions_cash_register_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_sessions
    ADD CONSTRAINT cash_sessions_cash_register_id_fkey FOREIGN KEY (cash_register_id) REFERENCES public.cash_registers(id);


--
-- Name: cash_sessions cash_sessions_closed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_sessions
    ADD CONSTRAINT cash_sessions_closed_by_user_id_fkey FOREIGN KEY (closed_by_user_id) REFERENCES public.users(id);


--
-- Name: cash_sessions cash_sessions_opened_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.cash_sessions
    ADD CONSTRAINT cash_sessions_opened_by_user_id_fkey FOREIGN KEY (opened_by_user_id) REFERENCES public.users(id);


--
-- Name: daily_preparations daily_preparations_article_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.daily_preparations
    ADD CONSTRAINT daily_preparations_article_id_fkey FOREIGN KEY (article_id) REFERENCES public.stock_articles(id) ON DELETE RESTRICT;


--
-- Name: daily_preparations daily_preparations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.daily_preparations
    ADD CONSTRAINT daily_preparations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: fne_documents fne_documents_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.fne_documents
    ADD CONSTRAINT fne_documents_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: fne_documents fne_documents_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.fne_documents
    ADD CONSTRAINT fne_documents_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: justificatifs justificatifs_operation_decaissement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.justificatifs
    ADD CONSTRAINT justificatifs_operation_decaissement_id_fkey FOREIGN KEY (operation_decaissement_id) REFERENCES public.operations_decaissement(id) ON DELETE CASCADE;


--
-- Name: justificatifs justificatifs_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.justificatifs
    ADD CONSTRAINT justificatifs_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: market_purchase_items market_purchase_items_article_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.market_purchase_items
    ADD CONSTRAINT market_purchase_items_article_id_fkey FOREIGN KEY (article_id) REFERENCES public.stock_articles(id) ON DELETE RESTRICT;


--
-- Name: market_purchase_items market_purchase_items_purchase_list_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.market_purchase_items
    ADD CONSTRAINT market_purchase_items_purchase_list_id_fkey FOREIGN KEY (purchase_list_id) REFERENCES public.market_purchase_lists(id) ON DELETE CASCADE;


--
-- Name: market_purchase_lists market_purchase_lists_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.market_purchase_lists
    ADD CONSTRAINT market_purchase_lists_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: market_purchase_lists market_purchase_lists_validated_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.market_purchase_lists
    ADD CONSTRAINT market_purchase_lists_validated_by_user_id_fkey FOREIGN KEY (validated_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: operations_decaissement operations_decaissement_autorisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_decaissement
    ADD CONSTRAINT operations_decaissement_autorisation_id_fkey FOREIGN KEY (autorisation_id) REFERENCES public.autorisations_depense(id) ON DELETE SET NULL;


--
-- Name: operations_decaissement operations_decaissement_caisse_journee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_decaissement
    ADD CONSTRAINT operations_decaissement_caisse_journee_id_fkey FOREIGN KEY (caisse_journee_id) REFERENCES public.caisse_journees(id) ON DELETE CASCADE;


--
-- Name: operations_decaissement operations_decaissement_categorie_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_decaissement
    ADD CONSTRAINT operations_decaissement_categorie_id_fkey FOREIGN KEY (categorie_id) REFERENCES public.categories_depense(id) ON DELETE SET NULL;


--
-- Name: operations_decaissement operations_decaissement_executant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_decaissement
    ADD CONSTRAINT operations_decaissement_executant_id_fkey FOREIGN KEY (executant_id) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: operations_decaissement operations_decaissement_fournisseur_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_decaissement
    ADD CONSTRAINT operations_decaissement_fournisseur_id_fkey FOREIGN KEY (fournisseur_id) REFERENCES public.fournisseurs(id) ON DELETE SET NULL;


--
-- Name: operations_encaissement operations_encaissement_caisse_journee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_encaissement
    ADD CONSTRAINT operations_encaissement_caisse_journee_id_fkey FOREIGN KEY (caisse_journee_id) REFERENCES public.caisse_journees(id) ON DELETE CASCADE;


--
-- Name: operations_encaissement operations_encaissement_executant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.operations_encaissement
    ADD CONSTRAINT operations_encaissement_executant_id_fkey FOREIGN KEY (executant_id) REFERENCES public.utilisateurs(id) ON DELETE SET NULL;


--
-- Name: order_items order_items_added_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_added_by_user_id_fkey FOREIGN KEY (added_by_user_id) REFERENCES public.users(id);


--
-- Name: order_items order_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: order_items order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: order_items order_items_removed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_removed_by_user_id_fkey FOREIGN KEY (removed_by_user_id) REFERENCES public.users(id);


--
-- Name: orders orders_cancelled_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_cancelled_by_user_id_fkey FOREIGN KEY (cancelled_by_user_id) REFERENCES public.users(id);


--
-- Name: orders orders_cash_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_cash_session_id_fkey FOREIGN KEY (cash_session_id) REFERENCES public.cash_sessions(id);


--
-- Name: orders orders_closed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_closed_by_user_id_fkey FOREIGN KEY (closed_by_user_id) REFERENCES public.users(id);


--
-- Name: orders orders_opened_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_opened_by_user_id_fkey FOREIGN KEY (opened_by_user_id) REFERENCES public.users(id);


--
-- Name: orders orders_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_table_id_fkey FOREIGN KEY (table_id) REFERENCES public.restaurant_tables(id);


--
-- Name: payments payments_cash_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_cash_session_id_fkey FOREIGN KEY (cash_session_id) REFERENCES public.cash_sessions(id);


--
-- Name: payments payments_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: payments payments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: print_jobs print_jobs_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.print_jobs
    ADD CONSTRAINT print_jobs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: print_jobs print_jobs_terminal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.print_jobs
    ADD CONSTRAINT print_jobs_terminal_id_fkey FOREIGN KEY (terminal_id) REFERENCES public.print_terminals(id) ON DELETE SET NULL;


--
-- Name: print_terminals print_terminals_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.print_terminals
    ADD CONSTRAINT print_terminals_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: product_components product_components_article_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.product_components
    ADD CONSTRAINT product_components_article_id_fkey FOREIGN KEY (article_id) REFERENCES public.stock_articles(id) ON DELETE RESTRICT;


--
-- Name: product_components product_components_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.product_components
    ADD CONSTRAINT product_components_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: product_price_history product_price_history_changed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.product_price_history
    ADD CONSTRAINT product_price_history_changed_by_user_id_fkey FOREIGN KEY (changed_by_user_id) REFERENCES public.users(id);


--
-- Name: product_price_history product_price_history_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.product_price_history
    ADD CONSTRAINT product_price_history_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: products products_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id);


--
-- Name: purchase_invoices purchase_invoices_received_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_invoices
    ADD CONSTRAINT purchase_invoices_received_by_user_id_fkey FOREIGN KEY (received_by_user_id) REFERENCES public.users(id);


--
-- Name: purchase_invoices purchase_invoices_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_invoices
    ADD CONSTRAINT purchase_invoices_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id);


--
-- Name: purchase_items purchase_items_purchase_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_items
    ADD CONSTRAINT purchase_items_purchase_invoice_id_fkey FOREIGN KEY (purchase_invoice_id) REFERENCES public.purchase_invoices(id) ON DELETE CASCADE;


--
-- Name: purchase_items purchase_items_raw_material_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_items
    ADD CONSTRAINT purchase_items_raw_material_id_fkey FOREIGN KEY (raw_material_id) REFERENCES public.raw_materials(id);


--
-- Name: purchase_request_lines purchase_request_lines_article_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_request_lines
    ADD CONSTRAINT purchase_request_lines_article_id_fkey FOREIGN KEY (article_id) REFERENCES public.stock_articles(id) ON DELETE RESTRICT;


--
-- Name: purchase_request_lines purchase_request_lines_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_request_lines
    ADD CONSTRAINT purchase_request_lines_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.purchase_requests(id) ON DELETE RESTRICT;


--
-- Name: purchase_request_lines purchase_request_lines_stock_movement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_request_lines
    ADD CONSTRAINT purchase_request_lines_stock_movement_id_fkey FOREIGN KEY (stock_movement_id) REFERENCES public.stock_movements(id) ON DELETE RESTRICT;


--
-- Name: purchase_requests purchase_requests_approved_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_requests
    ADD CONSTRAINT purchase_requests_approved_by_user_id_fkey FOREIGN KEY (approved_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: purchase_requests purchase_requests_closed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_requests
    ADD CONSTRAINT purchase_requests_closed_by_user_id_fkey FOREIGN KEY (closed_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: purchase_requests purchase_requests_disbursed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_requests
    ADD CONSTRAINT purchase_requests_disbursed_by_user_id_fkey FOREIGN KEY (disbursed_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: purchase_requests purchase_requests_received_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_requests
    ADD CONSTRAINT purchase_requests_received_by_user_id_fkey FOREIGN KEY (received_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: purchase_requests purchase_requests_requested_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.purchase_requests
    ADD CONSTRAINT purchase_requests_requested_by_user_id_fkey FOREIGN KEY (requested_by_user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: raw_material_movements raw_material_movements_purchase_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.raw_material_movements
    ADD CONSTRAINT raw_material_movements_purchase_invoice_id_fkey FOREIGN KEY (purchase_invoice_id) REFERENCES public.purchase_invoices(id) ON DELETE SET NULL;


--
-- Name: raw_material_movements raw_material_movements_raw_material_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.raw_material_movements
    ADD CONSTRAINT raw_material_movements_raw_material_id_fkey FOREIGN KEY (raw_material_id) REFERENCES public.raw_materials(id);


--
-- Name: raw_material_movements raw_material_movements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.raw_material_movements
    ADD CONSTRAINT raw_material_movements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: raw_materials raw_materials_default_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.raw_materials
    ADD CONSTRAINT raw_materials_default_supplier_id_fkey FOREIGN KEY (default_supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;


--
-- Name: stock_items stock_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_items
    ADD CONSTRAINT stock_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: stock_movements stock_movements_article_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_article_id_fkey FOREIGN KEY (article_id) REFERENCES public.stock_articles(id) ON DELETE RESTRICT;


--
-- Name: stock_movements stock_movements_reference_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_reference_order_id_fkey FOREIGN KEY (reference_order_id) REFERENCES public.orders(id) ON DELETE RESTRICT;


--
-- Name: stock_movements stock_movements_reference_order_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_reference_order_item_id_fkey FOREIGN KEY (reference_order_item_id) REFERENCES public.order_items(id) ON DELETE RESTRICT;


--
-- Name: stock_movements stock_movements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: utilisateurs utilisateurs_superette_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: caisse_user
--

ALTER TABLE ONLY public.utilisateurs
    ADD CONSTRAINT utilisateurs_superette_id_fkey FOREIGN KEY (superette_id) REFERENCES public.superettes(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

\unrestrict L8rFUxjqAEBLCgHzmhbaf4v23CdfnKTzFhqS1xaNDTImudqXW52WQSggVPa3MXw

