--
-- PostgreSQL database dump
--

\restrict jdveLgCcTpUNGdMQ2JjqTPy2aBcLaT2y0N6Gb0K4Ldu4KP23Ba0riq2wdVDut3g

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
015_purchase_requests_and_seq
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
8dde95d8-189e-413f-a428-456458b3ce24	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-09-29 20:58:29.786844+00	2026-09-29 20:58:29.786853+00
75345a70-320a-45b8-8e4f-757c143d2d52	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-09-29 20:58:33.583387+00	2026-09-29 20:58:33.583397+00
9e58d6de-ef17-401f-807d-114bf771850b	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-09-29 20:58:36.179643+00	2026-09-29 20:58:36.179651+00
8edd0430-1dc5-456f-bb81-fde9c1dd260f	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-09-29 20:58:59.03343+00	2026-09-29 20:58:59.03344+00
689c9890-f189-4936-8f38-6a6b533a04f3	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-03 16:15:53.372865+00	2026-10-03 16:15:53.372872+00
8388b947-1c91-489b-9767-3906dcbcf6db	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:16:01.629375+00	2026-10-03 16:16:01.629383+00
c8fc3ac2-5d29-4cde-be94-439e5ed75a51	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-03 16:17:39.276079+00	2026-10-03 16:17:39.276087+00
320a7348-cfe3-4fa5-b2cb-c5364397f53c	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-03 16:17:41.830136+00	2026-10-03 16:17:41.830144+00
426ec4e1-a828-490d-b3dd-bbc4a95b8db9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:28:52.439043+00	2026-10-03 16:28:52.439054+00
38315667-618d-4d67-ad6f-046d13234fd1	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:28:52.997796+00	2026-10-03 16:28:52.997809+00
c89b7eee-996e-4135-bb51-1bd8bab11378	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:29:19.705788+00	2026-10-03 16:29:19.705801+00
20448b83-1ed4-45f0-afca-99e1c93372d0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	POS-01	127.0.0.1	2026-10-03 16:45:20.816016+00	2026-10-03 16:45:20.816024+00
8253b9fd-c487-49ed-9fe9-e87f33e12ee5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	POS-01	127.0.0.1	2026-10-03 16:45:32.612103+00	2026-10-03 16:45:32.61211+00
26c1a32f-64fb-44b0-8ff0-b3f3578d2cc7	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	POS-01	127.0.0.1	2026-10-03 16:45:37.533842+00	2026-10-03 16:45:37.533854+00
9acd50cf-0db4-479a-b9e2-c6047e922586	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	POS-01	127.0.0.1	2026-10-03 16:46:35.450766+00	2026-10-03 16:46:35.450782+00
d8b6396c-e3f1-4424-a578-a97f45dc8c94	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:47:42.047593+00	2026-10-03 16:47:42.047605+00
3579cd4d-8a27-43f5-a2dc-72b842f2d855	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:48:41.509726+00	2026-10-03 16:48:41.509736+00
08fd3f7f-2e7d-48b4-96d4-261ed8fe8f52	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:51:04.185464+00	2026-10-03 16:51:04.185477+00
999dee83-7e68-4af5-bfaf-efdf4a1f9e36	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:55:13.882806+00	2026-10-03 16:55:13.882818+00
15ec39d8-8fa7-47bd-b7ee-1afcc01fd032	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	b4cb6a71-3495-4424-8391-10fa630880dd	null	{"opening_float_xof": 50000, "business_date": "2026-10-03"}	\N	caisse-01	\N	2026-10-03 16:55:14.068349+00	2026-10-03 16:55:14.068361+00
4a2281c5-0d5b-45ba-8ded-9f8b92822e5d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:55:34.750829+00	2026-10-03 16:55:34.750839+00
d6f9aac2-58cc-4407-93c2-c4b6e2143b00	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	6c0d982f-ac2f-4128-8407-1e2525edc1e3	null	{"order_number": "2026-10-03-0001", "table_id": "tbl-04", "guests_count": 4}	\N	caisse-01	\N	2026-10-03 16:56:49.275531+00	2026-10-03 16:56:49.275542+00
15df3355-7160-48ab-a6dc-5f2c80df08a0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1928db6f-1360-47f1-b17c-0cdd0edcc3ba	null	{"name": "Eau min\\u00e9rale Awa 1.5L", "quantity": 1, "line_total_xof": 700}	\N	caisse-01	\N	2026-10-03 16:56:49.386707+00	2026-10-03 16:56:49.386723+00
8a44bfb2-0ead-49a2-9d44-2560423cb785	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	60fd7735-259b-450c-901c-78a6d00a960f	null	{"name": "Capitaine brais\\u00e9 moyen", "quantity": 1, "line_total_xof": 6000}	\N	caisse-01	\N	2026-10-03 16:56:49.528744+00	2026-10-03 16:56:49.528758+00
a1f0940b-d59c-4144-9802-776e09909c46	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	38fbbf95-b1ad-49cf-bc52-823b2b68f9ad	null	{"name": "Choukouya de Poulet", "quantity": 1, "line_total_xof": 4500}	\N	caisse-01	\N	2026-10-03 16:56:49.638975+00	2026-10-03 16:56:49.638988+00
12e2bc78-465f-4d83-b8bb-f9baa8767173	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	b1be43b9-5a79-4395-b36f-c9568b3ee948	null	{"order_id": "6c0d982f-ac2f-4128-8407-1e2525edc1e3", "amount_xof": 11200, "method": "CASH", "order_status": "OPEN", "due_xof": 11200, "fne_requested": true}	\N	caisse-01	\N	2026-10-03 16:59:26.184076+00	2026-10-03 16:59:26.184083+00
369731b8-f85d-4d11-baa3-4db3754747e4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	a5d63e20-7b95-4efe-a246-8b554444fdf8	null	{"order_id": "6c0d982f-ac2f-4128-8407-1e2525edc1e3", "amount_xof": 11200, "method": "CASH", "order_status": "PARTIALLY_PAID", "due_xof": 11200, "fne_requested": true}	\N	caisse-01	\N	2026-10-03 16:59:41.148811+00	2026-10-03 16:59:41.148816+00
a3ecedef-b353-4318-83c0-ebabb18758b7	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-03 16:59:55.665021+00	2026-10-03 16:59:55.665035+00
f8b2509b-22ac-4e64-8595-491877df4dae	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 17:00:10.35313+00	2026-10-03 17:00:10.353141+00
b7f3bc76-875a-47d1-b99b-8b479f058f85	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-03 17:00:19.691032+00	2026-10-03 17:00:19.691041+00
87a3f1b3-006b-4bf8-9792-97c929809a6e	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-03 17:00:22.917079+00	2026-10-03 17:00:22.917089+00
ec91d878-e1e7-49f4-aceb-f5de323ac5fb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 17:00:25.398754+00	2026-10-03 17:00:25.398764+00
fedd6a94-8a68-4ec2-a6b2-8dfd3dd57b0f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	654d95f6-2bb0-4e6a-8f99-6c9d1ab4dd65	null	{"order_id": "6c0d982f-ac2f-4128-8407-1e2525edc1e3", "amount_xof": 11200, "method": "CASH", "order_status": "PARTIALLY_PAID", "due_xof": 11200, "fne_requested": true}	\N	caisse-01	\N	2026-10-03 17:01:08.269379+00	2026-10-03 17:01:08.269386+00
a1bd2624-b17f-4f1e-9f27-3b763aa65512	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 17:09:16.819099+00	2026-10-03 17:09:16.81911+00
bafd2a35-6127-4280-a1f6-593116c553b1	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-03 17:09:52.694015+00	2026-10-03 17:09:52.694023+00
966201b3-1ee6-4410-91f2-3d507d81dabf	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 17:09:55.558288+00	2026-10-03 17:09:55.558298+00
bcb13c44-cccd-4e3e-a86b-78bc6d1748b5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	8a6425e3-36f3-4f11-8bac-42a3fb6a5bc1	null	{"order_id": "6c0d982f-ac2f-4128-8407-1e2525edc1e3", "template": "B2B"}	\N	\N	\N	2026-10-03 17:10:11.024911+00	2026-10-03 17:10:11.024926+00
de085412-bbfd-42c2-b3b8-6fdc491d9528	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	4e1943ba-e9c5-4e84-bcc1-46b3833a229d	null	{"order_id": "6c0d982f-ac2f-4128-8407-1e2525edc1e3", "amount_xof": 11200, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-03 17:10:11.107765+00	2026-10-03 17:10:11.107779+00
6365bbfa-8b74-4cdd-a35b-f236e54aa68f	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-03 17:10:24.627677+00	2026-10-03 17:10:24.627688+00
63707c79-5113-4d4c-8122-3910dbd29b13	4b5224bf-057a-4654-b13e-0e65ff403161	\N	fne.retry	fne_document	8a6425e3-36f3-4f11-8bac-42a3fb6a5bc1	{"status": "PENDING", "last_error": null}	null	\N	\N	\N	2026-10-03 17:12:52.632294+00	2026-10-03 17:12:52.632306+00
93f98ccb-0d22-4576-978b-7460f9606f7c	4b5224bf-057a-4654-b13e-0e65ff403161	\N	fne.submit	fne_document	8a6425e3-36f3-4f11-8bac-42a3fb6a5bc1	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000001", "attempts": 1}	\N	\N	\N	2026-10-03 17:12:53.093403+00	2026-10-03 17:12:53.093413+00
9bf9e66c-3331-468a-ba7c-5886257b1a9e	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	POS-ADMIN	127.0.0.1	2026-10-03 17:24:34.620524+00	2026-10-03 17:24:34.620537+00
b5a98878-c139-4dda-9b06-365f1b2b7079	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	POS-ADMIN	127.0.0.1	2026-10-03 17:25:07.054725+00	2026-10-03 17:25:07.054735+00
8be5ea25-bb20-456e-86ca-e9e90f9d46ac	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-03 17:25:57.921091+00	2026-10-03 17:25:57.921103+00
6b60b675-c2e3-4af1-95bd-2676a52fa2b5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 17:26:01.022937+00	2026-10-03 17:26:01.022948+00
91272185-f192-4d6e-940f-633d3ad82312	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	b4cb6a71-3495-4424-8391-10fa630880dd	null	{"z_number": 1, "counted_cash_xof": 61200, "expected_cash_xof": 61200, "variance_xof": 0}	\N	caisse-01	\N	2026-10-03 17:26:28.994453+00	2026-10-03 17:26:28.994466+00
20536fa9-a816-49ef-a8ae-65eedae131b0	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-03 23:36:56.723858+00	2026-10-03 23:36:56.723866+00
66d58f9b-67a3-4bb3-9be8-090d8bf682bf	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-03 23:41:41.011909+00	2026-10-03 23:41:41.011921+00
9707ed86-b537-4104-9fb0-ff2293b41529	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-03 23:41:44.072292+00	2026-10-03 23:41:44.072303+00
89789cf6-367b-40fe-a72f-721b80434c3f	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-03 23:42:17.223219+00	2026-10-03 23:42:17.223231+00
eff59731-72f1-4e41-9e6d-92a13a0e610e	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-04 12:49:29.791709+00	2026-10-04 12:49:29.791719+00
1e7481d1-c7dd-4d6d-a4c6-f2c12a268028	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-04 12:52:58.807934+00	2026-10-04 12:52:58.807944+00
23c92952-9af1-4983-90fe-1d5d2b7d36af	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-04 12:53:02.186885+00	2026-10-04 12:53:02.186893+00
2bb65c39-9886-4065-8d34-2d6678323f4e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-04 12:57:09.478611+00	2026-10-04 12:57:09.478622+00
0aa6b291-35ba-4498-a71d-1fc6e267c20e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	657f9bb6-4f20-461b-aa55-414c36d51721	null	{"opening_float_xof": 50000, "business_date": "2026-10-04"}	\N	caisse-01	\N	2026-10-04 12:57:13.532728+00	2026-10-04 12:57:13.532742+00
4d1c33a3-8f04-419f-9b2d-5beff7040af3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	f583a914-9655-4ff4-9a88-a9e20f268e02	null	{"order_number": "2026-10-04-0001", "table_id": "tbl-07", "guests_count": 4}	\N	caisse-01	\N	2026-10-04 12:57:44.295019+00	2026-10-04 12:57:44.295026+00
ead802af-7c84-4806-9c13-3f1443045c93	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b3d0ba58-54bb-420f-88f4-bee0a2a8c3ff	null	{"name": "Capitaine brais\\u00e9 moyen", "quantity": 1, "line_total_xof": 6000}	\N	caisse-01	\N	2026-10-04 12:57:44.431578+00	2026-10-04 12:57:44.43159+00
bb43be1b-bed0-4721-a02b-e3e8b6a96651	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e7ba4a9d-2d37-45ed-b07a-cf35fde3f97a	null	{"name": "Choukouya de Poulet", "quantity": 1, "line_total_xof": 4500}	\N	caisse-01	\N	2026-10-04 12:57:44.516403+00	2026-10-04 12:57:44.516414+00
87476e11-ef7c-432f-a670-05b5b14d59e1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	bd14231c-47ca-4ba4-ba6f-13612926e7f6	null	{"name": "Eau min\\u00e9rale Awa 1.5L", "quantity": 1, "line_total_xof": 700}	\N	caisse-01	\N	2026-10-04 12:57:44.60396+00	2026-10-04 12:57:44.60397+00
ace8836d-ebc6-4db2-adbb-72ba041cb32e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	79d2111e-4117-40a9-95f7-448ead12a550	null	{"order_id": "f583a914-9655-4ff4-9a88-a9e20f268e02", "template": "B2B"}	\N	\N	\N	2026-10-04 12:59:32.692263+00	2026-10-04 12:59:32.692273+00
adb1a048-57b8-4d53-ae23-05f50cafb42b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	43743d45-eeb7-4182-bfb8-5cc3ebd512fc	null	{"order_id": "f583a914-9655-4ff4-9a88-a9e20f268e02", "amount_xof": 11200, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-04 12:59:33.139335+00	2026-10-04 12:59:33.139344+00
070e5b85-dbc1-4e93-bb89-06f4754cde6d	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-04 13:00:10.783088+00	2026-10-04 13:00:10.783098+00
bc399075-3991-4bd3-9b62-601848b53723	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	fne.retry	fne_document	79d2111e-4117-40a9-95f7-448ead12a550	{"status": "PENDING", "last_error": null}	null	\N	\N	\N	2026-10-04 13:02:32.519012+00	2026-10-04 13:02:32.51902+00
0773d73a-6587-4ae0-ae7c-d128247a5a7c	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	fne.submit	fne_document	79d2111e-4117-40a9-95f7-448ead12a550	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000002", "attempts": 1}	\N	\N	\N	2026-10-04 13:02:32.987841+00	2026-10-04 13:02:32.98788+00
bbd21ad1-9e60-48b5-aba2-82a25fba99b1	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-04 19:29:53.920829+00	2026-10-04 19:29:53.920836+00
5f160930-ed83-4cb9-ade2-f23d2c9cb7b3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-04 19:30:21.181763+00	2026-10-04 19:30:21.181777+00
614ca440-adde-4a97-a168-8a215df735cd	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	657f9bb6-4f20-461b-aa55-414c36d51721	null	{"z_number": 2, "counted_cash_xof": 61200, "expected_cash_xof": 61200, "variance_xof": 0}	\N	caisse-01	\N	2026-10-04 19:31:18.499621+00	2026-10-04 19:31:18.49963+00
bcb52eac-7d7d-44dc-8453-3902a51931bb	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-04 22:27:00.052391+00	2026-10-04 22:27:00.052401+00
f22aa77c-213e-4c04-bb37-0328a0a5401a	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-04 22:34:33.055847+00	2026-10-04 22:34:33.055858+00
2d6943ba-30fe-4f00-a6df-73c20864e259	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-04 22:38:44.002431+00	2026-10-04 22:38:44.002441+00
80e5e47c-5115-4fe9-9646-23d0a7497886	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-05 09:52:34.667049+00	2026-10-05 09:52:34.667113+00
0ee5413f-df8f-4e73-88f0-fd74f545ca1e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	19d6f69e-d507-4703-ad46-1168b31c4ef9	null	{"order_id": "0e284d1f-25f4-4a12-8cdd-7fd9a6580b29", "amount_xof": 16000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-05 09:56:44.44372+00	2026-10-05 09:56:44.443726+00
7e837fc5-1a45-4513-9995-aa6b5ed43ecd	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-04 22:42:00.739636+00	2026-10-04 22:42:00.739646+00
4e0ba080-6128-4bc9-890f-a4ee2dc2d494	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-04 22:42:12.609096+00	2026-10-04 22:42:12.609106+00
7f92edc0-5a93-48ba-bdb5-d2c73ba4c541	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-05 09:49:42.226143+00	2026-10-05 09:49:42.226156+00
57f9854d-1ad6-40b1-8a6c-ea49331a6a2c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	d6b98cac-691c-4ab0-8ebc-b94c2bbb3638	null	{"opening_float_xof": 50000, "business_date": "2026-10-05"}	\N	caisse-01	\N	2026-10-05 09:49:57.462958+00	2026-10-05 09:49:57.462969+00
c7aed1f6-09ea-46d8-89b2-df975e956e58	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-05 09:52:32.012543+00	2026-10-05 09:52:32.01255+00
1376d5fb-370d-4e71-a044-584857b20252	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	0e284d1f-25f4-4a12-8cdd-7fd9a6580b29	null	{"order_number": "2026-10-05-0001", "table_id": "tbl-07", "guests_count": 4}	\N	caisse-01	\N	2026-10-05 09:53:37.170696+00	2026-10-05 09:53:37.170708+00
b0e19d9b-21e7-4dfc-ac46-2b95a1f2883a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	30bcefb8-fc88-4f85-84e4-b7e95187e7b8	null	{"name": "Choukouya de Poulet", "quantity": 1, "line_total_xof": 4500}	\N	caisse-01	\N	2026-10-05 09:53:37.256106+00	2026-10-05 09:53:37.256118+00
140ee26d-e3a8-4a53-9e91-74b2910788a1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	33a2de29-4dc4-4cc5-894b-e2d5e26198bd	null	{"name": "Capitaine brais\\u00e9 moyen", "quantity": 1, "line_total_xof": 6000}	\N	caisse-01	\N	2026-10-05 09:53:37.346167+00	2026-10-05 09:53:37.34618+00
86bd0388-5264-40b8-987e-6b4952f2e4ee	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ed352361-88aa-4880-a02e-bfd0b2d8a4ad	null	{"name": "Carpe brais\\u00e9e grande", "quantity": 1, "line_total_xof": 5500}	\N	caisse-01	\N	2026-10-05 09:53:37.41564+00	2026-10-05 09:53:37.415649+00
755cf965-64b6-4495-9856-34976e13d5ca	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	0ed73dde-89de-488c-a6e8-6ec5500904af	null	{"order_id": "0e284d1f-25f4-4a12-8cdd-7fd9a6580b29", "template": "B2B"}	\N	\N	\N	2026-10-05 09:56:44.277456+00	2026-10-05 09:56:44.277465+00
24e7a1cb-b192-4fe8-9884-9080701cb825	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 09:49:49.774294+00	2026-10-05 09:49:49.774303+00
f52255ed-1f84-47cf-bbe9-b146a73bf2a5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 10:00:51.705272+00	2026-10-05 10:00:51.705283+00
9e5c9902-4282-4cb1-bdf6-4ce603f6b3ef	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 10:12:53.184455+00	2026-10-05 10:12:53.184467+00
9412c011-ad58-4071-9a8b-1528a9ff7650	4b5224bf-057a-4654-b13e-0e65ff403161	\N	fne.retry	fne_document	0ed73dde-89de-488c-a6e8-6ec5500904af	{"status": "PENDING", "last_error": null}	null	\N	\N	\N	2026-10-05 10:20:01.387528+00	2026-10-05 10:20:01.387537+00
c7e0a947-8f8b-4971-8ec2-bea2f3b5a362	4b5224bf-057a-4654-b13e-0e65ff403161	\N	fne.submit	fne_document	0ed73dde-89de-488c-a6e8-6ec5500904af	null	{"status": "SUBMITTING", "is_uncertain": true, "external_number": null, "attempts": 1}	\N	\N	\N	2026-10-05 10:20:05.443568+00	2026-10-05 10:20:05.443575+00
7eacbc3b-3d17-4eae-b410-037617de7738	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 10:26:52.746817+00	2026-10-05 10:26:52.746829+00
f7f039b7-0cc8-45d4-b355-099c6803f9b5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	98c9428e-4f3d-4161-8ed8-08e405057330	null	{"order_number": "2026-10-05-0002", "table_id": "tbl-03", "guests_count": 4}	\N	caisse-01	\N	2026-10-05 10:27:23.028127+00	2026-10-05 10:27:23.028136+00
7e518da0-9005-4416-a255-d6c929ad7f86	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	25b7e765-ca52-4fc9-b19f-fa00075c3de5	null	{"name": "Bi\\u00e8re Bock 65cl", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-05 10:27:23.097301+00	2026-10-05 10:27:23.097312+00
b9bad388-79ec-4c61-afcc-5b0db82377fc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	edcb916f-38ef-4599-b124-6a1f0ffb1158	null	{"name": "Choukouya de Poulet", "quantity": 1, "line_total_xof": 4500}	\N	caisse-01	\N	2026-10-05 10:27:23.181104+00	2026-10-05 10:27:23.181111+00
5db0351a-f14a-4e5c-9e0a-8b68e8a5f78e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	9211e12c-8f03-4d75-ace9-5eaf09a1e1f2	null	{"order_number": "2026-10-05-0003", "table_id": "tbl-05", "guests_count": 4}	\N	caisse-01	\N	2026-10-05 10:27:40.88608+00	2026-10-05 10:27:40.88609+00
66243995-a585-4813-8e8c-8314e4815f42	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0a2c388d-54c9-4959-85de-70c01a4c5098	null	{"name": "Carpe brais\\u00e9e grande", "quantity": 1, "line_total_xof": 5500}	\N	caisse-01	\N	2026-10-05 10:27:40.988719+00	2026-10-05 10:27:40.988729+00
f647cd2f-146c-4862-a23c-382c03c7494e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ff685081-2418-4304-ab09-696e2088b448	null	{"name": "Eau min\\u00e9rale Awa 1.5L", "quantity": 2, "line_total_xof": 1400}	\N	caisse-01	\N	2026-10-05 10:27:42.26538+00	2026-10-05 10:27:42.265388+00
05013123-51ea-4cab-8dc2-5c3c0297194c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	775a731b-a3a7-44a6-8fb0-d2b887d818f2	null	{"order_number": "2026-10-05-0004", "table_id": "tbl-04", "guests_count": 4}	\N	caisse-01	\N	2026-10-05 10:28:20.411647+00	2026-10-05 10:28:20.41166+00
588ec332-2f6e-4485-a442-9979a9c48e07	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b280fb04-ffe7-4839-9d59-592046dd48e0	null	{"name": "Eau min\\u00e9rale Awa 1.5L", "quantity": 1, "line_total_xof": 700}	\N	caisse-01	\N	2026-10-05 10:28:20.520513+00	2026-10-05 10:28:20.520524+00
dbc2124b-6069-4c01-993c-d18029969f2d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	f14685bc-d0d3-40cb-92fb-c0bc1d4d7afb	null	{"name": "Capitaine brais\\u00e9 moyen", "quantity": 1, "line_total_xof": 6000}	\N	caisse-01	\N	2026-10-05 10:28:20.621224+00	2026-10-05 10:28:20.621232+00
af2fa96d-7b04-4872-893b-ff752d4b723e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 10:38:29.45624+00	2026-10-05 10:38:29.456248+00
976e0c14-0d2b-4f7e-b638-ebc608bc5dbc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	970a0966-5976-42d7-a68a-a28c6de569b8	null	{"order_id": "9211e12c-8f03-4d75-ace9-5eaf09a1e1f2", "template": "B2B"}	\N	\N	\N	2026-10-05 10:41:01.75578+00	2026-10-05 10:41:01.755792+00
6fa27986-ae97-4e5c-9ea8-280e4407c301	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	970a0966-5976-42d7-a68a-a28c6de569b8	null	{"status": "SUBMITTING", "is_uncertain": true, "external_number": null, "attempts": 1}	\N	\N	\N	2026-10-05 10:41:05.787926+00	2026-10-05 10:41:05.787937+00
efd4d9fe-17d9-4e78-9192-12fd933ad277	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	53bc0ee8-bfb1-42ad-b267-93090024a511	null	{"order_id": "9211e12c-8f03-4d75-ace9-5eaf09a1e1f2", "amount_xof": 6900, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-05 10:41:05.979979+00	2026-10-05 10:41:05.979986+00
c666deb1-ceee-488d-b31b-adc2c0e0a053	4b5224bf-057a-4654-b13e-0e65ff403161	\N	fne.resolve	fne_document	970a0966-5976-42d7-a68a-a28c6de569b8	{"status": "SUBMITTING", "last_error": "FneUncertainError: issue inconnue : ReadTimeout('timed out')"}	{"is_certified": true, "external_number": "9506466A"}	\N	\N	\N	2026-10-05 10:44:27.402259+00	2026-10-05 10:44:27.402301+00
12b8644d-55d7-4320-b309-2718dc55105e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 11:03:42.650527+00	2026-10-05 11:03:42.650537+00
26b2dabf-9536-4055-9bbb-f2106f3c5092	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 11:03:54.86052+00	2026-10-05 11:03:54.860537+00
9529d086-db1f-40c2-a23e-61b4b321c083	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 11:04:05.790201+00	2026-10-05 11:04:05.790212+00
98730fbe-b839-4efa-8523-e586da34c027	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	4437c102-d5cd-4101-85f6-555b57e5b200	null	{"order_id": "775a731b-a3a7-44a6-8fb0-d2b887d818f2", "template": "B2B"}	\N	\N	\N	2026-10-05 11:07:23.763875+00	2026-10-05 11:07:23.763885+00
eb712845-3cb4-49f8-8638-79a62344185b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	4437c102-d5cd-4101-85f6-555b57e5b200	null	{"status": "SUBMITTING", "is_uncertain": true, "external_number": null, "attempts": 1}	\N	\N	\N	2026-10-05 11:07:38.824398+00	2026-10-05 11:07:38.824407+00
85a78cbe-858e-4bef-abab-8ed560c90611	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	c46abd8d-3f20-44a6-b488-f5c3fc71ae60	null	{"order_id": "775a731b-a3a7-44a6-8fb0-d2b887d818f2", "amount_xof": 6700, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-05 11:07:38.888755+00	2026-10-05 11:07:38.888765+00
1f88ef52-61e2-427b-a26f-9d66f3eed40a	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-05 11:08:15.745586+00	2026-10-05 11:08:15.745594+00
ebcdc2e3-bb2e-4e01-9411-255cea5aac4a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 11:19:41.89636+00	2026-10-05 11:19:41.896374+00
2f2c8e4d-1659-4e26-af1a-1827eb3b48c3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	6b04194e-761a-4cd5-a7b7-f9652926a0b0	null	{"order_id": "98c9428e-4f3d-4161-8ed8-08e405057330", "template": "B2C"}	\N	\N	\N	2026-10-05 11:20:03.747304+00	2026-10-05 11:20:03.747315+00
93f894ff-d53b-48a8-a51c-68d73363fc35	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	6b04194e-761a-4cd5-a7b7-f9652926a0b0	null	{"status": "SUBMITTING", "is_uncertain": true, "external_number": null, "attempts": 1}	\N	\N	\N	2026-10-05 11:20:18.809182+00	2026-10-05 11:20:18.809192+00
6f081f9d-03e6-4759-9d67-edeecf7c6344	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-08 10:41:41.904893+00	2026-10-08 10:41:41.904903+00
aca52fcd-85f5-4363-995e-d04b7556ad9f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	073b759a-9f04-4923-afa0-12d2f25593d6	null	{"order_id": "98c9428e-4f3d-4161-8ed8-08e405057330", "amount_xof": 5500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-05 11:20:18.876963+00	2026-10-05 11:20:18.87697+00
bdc266dc-946f-4fdb-8492-ca8be65bb015	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 11:43:11.203732+00	2026-10-05 11:43:11.203744+00
b73c50c3-1c53-4450-aa62-3d8428169134	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	030abd10-6cf1-4b0b-982a-6d0b7cf2d788	null	{"order_number": "2026-10-05-0005", "table_id": "tbl-08", "guests_count": 4}	\N	caisse-01	\N	2026-10-05 11:43:32.640718+00	2026-10-05 11:43:32.640728+00
2e09aa6d-1171-4802-a717-ed99540d7d04	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	459df01d-9aa7-4f16-8ab9-b886d4605976	null	{"name": "Choukouya de Poulet", "quantity": 1, "line_total_xof": 4500}	\N	caisse-01	\N	2026-10-05 11:43:32.73821+00	2026-10-05 11:43:32.738224+00
2d371528-487d-4714-9e6f-f78da0e62029	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4f0d4b29-7a98-4001-84d9-9ae3fa548b7e	null	{"name": "Bi\\u00e8re Bock 65cl", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-05 11:43:32.842426+00	2026-10-05 11:43:32.842436+00
26ba7e41-e046-41ae-9f78-c15017d64fbe	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a7f9d6ba-d894-4357-a63c-965c3c50e15e	null	{"name": "Eau min\\u00e9rale Awa 1.5L", "quantity": 1, "line_total_xof": 700}	\N	caisse-01	\N	2026-10-05 11:43:32.929856+00	2026-10-05 11:43:32.929869+00
9858370a-2801-45f0-9893-50600b7e3678	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b8a4ab7e-6f88-4d3c-9716-8bd6439841fe	null	{"name": "Carpe brais\\u00e9e grande", "quantity": 1, "line_total_xof": 5500}	\N	caisse-01	\N	2026-10-05 11:43:33.08255+00	2026-10-05 11:43:33.082562+00
f44c17be-4dfc-4d96-8519-978f38e10099	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3a0c0d4e-8b8b-452e-b340-d6de9a61cc5e	null	{"name": "Capitaine brais\\u00e9 moyen", "quantity": 1, "line_total_xof": 6000}	\N	caisse-01	\N	2026-10-05 11:43:33.167378+00	2026-10-05 11:43:33.167387+00
5d1211fe-e55a-4aee-a85b-37b6bab04ebd	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	bcd9af4b-c957-43b1-a045-45c13b43df69	null	{"order_number": "2026-10-05-0006", "table_id": "tbl-03", "guests_count": 4}	\N	caisse-01	\N	2026-10-05 11:43:54.654557+00	2026-10-05 11:43:54.654566+00
21313674-d25f-460c-bb9b-1333bf7ab85a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	8c1fe8d0-596a-4cc2-a79a-dc9a686cc11f	null	{"name": "Choukouya de Poulet", "quantity": 1, "line_total_xof": 4500}	\N	caisse-01	\N	2026-10-05 11:43:54.718721+00	2026-10-05 11:43:54.718734+00
746d2c93-bb20-4c68-946f-3f3e4099a96d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3116413e-fd71-49e8-a728-3a9a4fdb65a4	null	{"name": "Eau min\\u00e9rale Awa 1.5L", "quantity": 1, "line_total_xof": 700}	\N	caisse-01	\N	2026-10-05 11:43:54.810543+00	2026-10-05 11:43:54.810553+00
61c4ff6c-4d7f-45cf-a517-3ee3eadf290d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 11:51:06.983351+00	2026-10-05 11:51:06.98336+00
a1f753a4-b04f-4c06-b5eb-d6a755521b08	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 12:11:31.886425+00	2026-10-05 12:11:31.886438+00
b719cb61-3b59-4c08-a367-b5e4b3438e03	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	9d8f4163-a476-4195-a9cb-e044316a684d	null	{"order_id": "bcd9af4b-c957-43b1-a045-45c13b43df69", "amount_xof": 5200, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-05 12:14:55.611195+00	2026-10-05 12:14:55.611204+00
2e9e533b-6165-4ad8-9839-7d6ad30e29d8	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-05 14:30:39.466856+00	2026-10-05 14:30:39.466868+00
96ed4099-4822-47ed-ba35-16cf84d3ab15	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 14:33:57.559072+00	2026-10-05 14:33:57.55908+00
5b8923ab-94fc-485f-8f08-870623eeecf3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	7edd1da0-660e-4442-8ac1-1a0b3bc91114	null	{"order_id": "030abd10-6cf1-4b0b-982a-6d0b7cf2d788", "template": "B2B"}	\N	\N	\N	2026-10-05 14:36:51.42092+00	2026-10-05 14:36:51.420929+00
fa556596-7bfa-4c27-8adc-daf3840b78f3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	7edd1da0-660e-4442-8ac1-1a0b3bc91114	null	{"status": "SUBMITTING", "is_uncertain": true, "external_number": null, "attempts": 1}	\N	\N	\N	2026-10-05 14:36:55.47186+00	2026-10-05 14:36:55.471868+00
3c89a6c8-43f4-49a5-9aeb-00e4d6765ee6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	0ed26434-1759-45a4-bb1d-486afabcf573	null	{"order_id": "030abd10-6cf1-4b0b-982a-6d0b7cf2d788", "amount_xof": 17700, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-05 14:36:55.526868+00	2026-10-05 14:36:55.526876+00
209fd4b7-45bb-405f-af14-161b44f4fc8c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	83f9e604-0014-4ef6-ba66-a078eda24cd7	null	{"order_number": "2026-10-05-0007", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-05 14:40:23.065475+00	2026-10-05 14:40:23.065486+00
818ae734-8d96-416b-b03f-e15161b88ab6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	89523572-0412-4ccc-a8b4-8622b615f585	null	{"name": "Capitaine brais\\u00e9 moyen", "quantity": 3, "line_total_xof": 18000}	\N	caisse-01	\N	2026-10-05 14:40:23.146233+00	2026-10-05 14:40:23.146244+00
00b56e27-5820-488a-a34a-b541d17ef506	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	f2fcc91f-cc3d-4a0c-858f-e277a76c5e28	null	{"name": "Eau min\\u00e9rale Awa 1.5L", "quantity": 3, "line_total_xof": 2100}	\N	caisse-01	\N	2026-10-05 14:40:23.200244+00	2026-10-05 14:40:23.200254+00
bb4a1448-e5ad-4cc3-8d30-50d23b12ef09	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	8a598b1b-8660-46fa-a2f1-82e221c9876f	null	{"order_id": "83f9e604-0014-4ef6-ba66-a078eda24cd7", "amount_xof": 20100, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-05 14:40:31.314363+00	2026-10-05 14:40:31.31437+00
5ffc598a-7ca2-40d1-bcef-4ac973268065	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 14:49:14.139891+00	2026-10-05 14:49:14.1399+00
efb16d37-2213-4663-928d-b017a1c5b997	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	5f6889e2-f5e1-4447-aca0-fc4649a79365	null	{"order_number": "2026-10-05-0008", "table_id": "tbl-01", "guests_count": 1}	\N	caisse-01	\N	2026-10-05 14:49:41.84865+00	2026-10-05 14:49:41.84866+00
8a231d81-6115-4fc9-b4a1-b9469a605cb5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	90330b57-f0ba-4a36-af29-3829750a3886	null	{"name": "Choukouya de Poulet", "quantity": 3, "line_total_xof": 13500}	\N	caisse-01	\N	2026-10-05 14:49:41.913532+00	2026-10-05 14:49:41.913542+00
8f1268bf-bfb2-4594-8e2e-ccae3f2ec0f3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e4d45427-efac-4fe7-84d8-35ce5ec95137	null	{"name": "Bi\\u00e8re Bock 65cl", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-05 14:49:42.020278+00	2026-10-05 14:49:42.02029+00
676771b1-40ec-41ea-906f-96a6cac1d312	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0974bd1c-762f-42cd-9b14-48f9f866fd3d	null	{"name": "Eau min\\u00e9rale Awa 1.5L", "quantity": 1, "line_total_xof": 700}	\N	caisse-01	\N	2026-10-05 14:49:42.105796+00	2026-10-05 14:49:42.105807+00
88b70120-4366-4fcd-a097-090ab1019ed1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 14:53:29.779219+00	2026-10-05 14:53:29.779228+00
e50766ec-a208-486f-91c3-a9e75ed5741b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	95113f8e-4a64-4081-9eeb-a7d83a0e9d97	null	{"order_id": "5f6889e2-f5e1-4447-aca0-fc4649a79365", "template": "B2B"}	\N	\N	\N	2026-10-05 14:54:43.769374+00	2026-10-05 14:54:43.769385+00
fb402d63-44a8-4f1f-9429-ef742f70fce7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	4f6aa384-3e52-47e3-9237-534c78e40796	null	{"order_id": "5f6889e2-f5e1-4447-aca0-fc4649a79365", "amount_xof": 15200, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-05 14:54:47.854733+00	2026-10-05 14:54:47.854743+00
d51e18cc-f877-402f-9cf5-303649919424	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	95113f8e-4a64-4081-9eeb-a7d83a0e9d97	null	{"status": "SUBMITTING", "is_uncertain": true, "external_number": null, "attempts": 1}	\N	\N	\N	2026-10-05 14:54:47.792503+00	2026-10-05 14:54:47.792511+00
87046e45-c791-4383-8ace-d52ab6b8da32	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-05 16:09:49.727208+00	2026-10-05 16:09:49.727217+00
46e21685-86ef-4e3b-8d48-17acc6705530	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 16:09:56.697868+00	2026-10-05 16:09:56.697878+00
41bd766d-1895-477d-9bba-b7c3199fde84	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 16:10:05.494384+00	2026-10-05 16:10:05.494393+00
8a16ac80-1bdd-411c-968d-f1c58cd3c374	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-05 16:22:15.956965+00	2026-10-05 16:22:15.956972+00
37993837-6ce5-405f-a8a7-91c4ca00a93f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	d6b98cac-691c-4ab0-8ebc-b94c2bbb3638	null	{"z_number": 3, "counted_cash_xof": 143300, "expected_cash_xof": 143300, "variance_xof": 0}	\N	caisse-01	\N	2026-10-05 16:23:14.843942+00	2026-10-05 16:23:14.843951+00
0497914e-b1d1-4a6a-84e0-96a76e7f622c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	Z_REPORT_PRINTED	CASH_SESSION	d6b98cac-691c-4ab0-8ebc-b94c2bbb3638	null	{"print_job_id": "7e2f02b2-666b-4b86-acf1-c4e89a0a765b", "z_number": 3}	\N	DEV-01	\N	2026-10-05 16:32:50.672554+00	2026-10-05 16:32:50.672563+00
efe5fd66-ab24-4ce5-b9ce-37fdfd529199	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	Z_REPORT_PRINTED	CASH_SESSION	d6b98cac-691c-4ab0-8ebc-b94c2bbb3638	null	{"print_job_id": "dfe6747e-4455-46f0-9c32-dcd871d3e3ba", "z_number": 3}	\N	caisse-01	\N	2026-10-05 16:38:01.594863+00	2026-10-05 16:38:01.594872+00
55d7daee-aa9a-4718-ab4d-778f1a8f8ec5	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-06 10:35:17.804114+00	2026-10-06 10:35:17.804302+00
59bb6d83-5a94-42b0-9f43-d67f96f92c7c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 10:35:20.218019+00	2026-10-06 10:35:20.218028+00
6bb25590-6ca9-44e8-9905-1d2837a49feb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	134c4e75-7d4a-4480-9dd7-a813d6a9fabc	null	{"opening_float_xof": 50000, "business_date": "2026-10-06"}	\N	caisse-01	\N	2026-10-06 10:35:23.459542+00	2026-10-06 10:35:23.45955+00
20b09b84-2e0f-430b-9bb2-243b00569fb2	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-06 10:57:17.153872+00	2026-10-06 10:57:17.15388+00
a6d6d5f8-105c-4021-bd73-bf2b26293d93	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 11:07:26.739024+00	2026-10-06 11:07:26.739033+00
5694be5e-82cb-4df7-8e51-d7e128fd8046	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	61245d2f-8301-4acc-a965-12f74778b946	null	{"opening_float_xof": 50000, "business_date": "2026-10-06"}	\N	caisse-01	\N	2026-10-06 11:07:33.754224+00	2026-10-06 11:07:33.754232+00
0aa77bfa-b0f4-44b7-a5d6-46debfc55062	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 11:10:54.901389+00	2026-10-06 11:10:54.901397+00
9186e4b9-18f0-4a72-8fe5-06c0f66858ac	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-06 11:11:47.204955+00	2026-10-06 11:11:47.204962+00
37b208ba-14b0-4d4a-b6a3-b0368d19ce2a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 11:18:36.06768+00	2026-10-06 11:18:36.067687+00
e0239377-187c-4258-bfa6-22d6ff4f4396	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 11:22:14.47282+00	2026-10-06 11:22:14.472829+00
a99d0c4e-ba63-4873-b6de-bd9de07744fd	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	null	{"order_number": "2026-10-06-0001", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-06 11:28:02.521822+00	2026-10-06 11:28:02.521835+00
ac03b1ce-b75c-447c-887c-8f3a1b8438ed	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1d75d76b-8dad-4410-83f1-b5e7e8935356	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-06 11:28:02.624949+00	2026-10-06 11:28:02.624966+00
44a446f6-1e72-4684-a652-0d2c3922186e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6a1c51f4-6477-4bf1-969d-6e160d91fc09	null	{"name": "Frites + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-06 11:28:02.785399+00	2026-10-06 11:28:02.785421+00
29e21702-66b2-40f8-a8d3-7adab7212678	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	05724252-3c5b-44a0-bd40-0cac6287d211	null	{"name": "Salade Panach\\u00e9e + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 11:28:02.906376+00	2026-10-06 11:28:02.906392+00
3da5bfc3-1dcc-491c-8bfc-5583f2534896	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	4dca0121-6712-4315-8098-c7cb86dad49d	null	{"order_number": "2026-10-06-0002", "table_id": "6cf24b95-3c1e-473d-bdd8-2f22c321b558", "guests_count": 4}	\N	caisse-01	\N	2026-10-06 11:28:45.523318+00	2026-10-06 11:28:45.523331+00
99d77876-d925-4a0a-be54-40538652ab45	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0c7909cf-44e5-43d8-916b-7cf7cb48f177	null	{"name": "Sauce Feuille + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 11:28:45.604729+00	2026-10-06 11:28:45.604744+00
a28298c5-86a1-45ce-b300-82ad348f7c59	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	cecee6b7-6b3d-438a-a7a1-edb25a8df644	null	{"name": "D\\u00e9gu\\u00e9", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-06 11:28:45.760138+00	2026-10-06 11:28:45.760154+00
bfd86f96-4596-44eb-a6bc-284aeff7eb9e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9c231e6e-f5b6-48ad-89d9-491354a229bc	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-06 11:28:45.873777+00	2026-10-06 11:28:45.873798+00
35d97e88-7c2a-4576-a662-dc9b29a63096	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	null	{"order_number": "2026-10-06-0003", "table_id": "f3904853-0688-4341-9830-a0a9716161bc", "guests_count": 4}	\N	caisse-01	\N	2026-10-06 11:29:23.376168+00	2026-10-06 11:29:23.376182+00
c03e6923-50fe-4335-9690-b9840b7b2900	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a467acd3-759c-497a-be87-091ce6c653b1	null	{"name": "Kabato Kope + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-06 11:29:23.464956+00	2026-10-06 11:29:23.464974+00
976d93e5-b36e-4443-bc95-7f7c19b2353e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	972d450b-52f5-4ef9-8266-9c65babdf378	null	{"name": "Kabato Lafri + Tripe", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 11:29:23.585924+00	2026-10-06 11:29:23.585956+00
faf57c6f-605c-4892-a1ff-e59e664c0236	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c77f25ca-f040-46d8-afc9-696221641ae4	null	{"name": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-06 11:29:23.731627+00	2026-10-06 11:29:23.731642+00
01b242f4-87ce-43a3-905c-2ae9d339f666	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3df78cc4-400b-4f7c-8de1-f74788ca3419	null	{"name": "Yassa + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 11:29:23.870931+00	2026-10-06 11:29:23.870952+00
4167be40-71a5-4b58-8a12-193f5ed9c87e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	85dea713-026e-4ed8-99fa-72a1e9604ee5	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-06 11:29:23.968078+00	2026-10-06 11:29:23.968099+00
38424e7c-f8d1-4732-ada7-ee96a4c62925	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3e607162-05f7-4db6-aea6-9ede78e3f561	null	{"name": "Passion", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-06 11:29:24.074736+00	2026-10-06 11:29:24.074765+00
74d234e8-7e54-49a4-ac34-276bf3cc6b55	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	99de95c7-e757-4f90-b487-5dbc9159bdbd	null	{"order_id": "b61f47d3-6a41-4cbb-bc0c-84fcc09036f5", "template": "B2B"}	\N	\N	\N	2026-10-06 11:30:12.914341+00	2026-10-06 11:30:12.914363+00
85507c69-9d29-43b5-9d9a-c532a3ec4c82	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 10:42:04.038689+00	2026-10-08 10:42:04.0387+00
a0df124a-5d56-462b-a743-e9780363d1db	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	99de95c7-e757-4f90-b487-5dbc9159bdbd	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000004", "attempts": 1}	\N	\N	\N	2026-10-06 11:30:14.445726+00	2026-10-06 11:30:14.445736+00
f8028a21-5b36-4391-80fb-6e963bac4734	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 11:47:12.004452+00	2026-10-06 11:47:12.004463+00
d93c1908-3f38-4259-8cb5-e735a24435df	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 11:53:28.208659+00	2026-10-06 11:53:28.208669+00
03d33382-11a1-433d-8ebf-5242116a99ec	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 12:01:58.384492+00	2026-10-06 12:01:58.384504+00
2b583b7a-8974-4e08-84d4-f38c0e296a8b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	fdc1b12e-9132-444b-9f07-d929dbf2fac4	null	{"name": "Frites + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-06 12:02:40.745283+00	2026-10-06 12:02:40.745295+00
ac237f21-8507-45db-a2a8-093c20b929d3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 14:28:12.655884+00	2026-10-06 14:28:12.65589+00
18c658ea-5b88-4c47-8bcd-669291450ba0	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-06 14:29:44.14504+00	2026-10-06 14:29:44.14505+00
b79eed52-3eb3-4896-90bc-f6199a5e4b6d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	57cbe577-16ce-4a6b-beae-2e0d0957b337	null	{"name": "Kabato Lafri + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-06 14:30:35.270763+00	2026-10-06 14:30:35.270776+00
61cd3b9f-6bd9-410c-a5fd-09191d1fcb60	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b775560e-0fdb-4776-9d72-504d3c2ef3de	null	{"name": "Igname frite + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-06 14:30:35.573879+00	2026-10-06 14:30:35.573891+00
9da8dee7-381d-48b4-8ff1-70bafb2d65b8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4427f74c-1f8b-433c-83e4-55a1607e244f	null	{"name": "Kabato Dah + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-06 14:31:30.838398+00	2026-10-06 14:31:30.838412+00
b535d479-1acc-4c1a-97a1-dc0e6c15439b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9305284b-32d8-447f-9d80-46f6b143acf1	null	{"name": "Frites + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 14:32:06.667829+00	2026-10-06 14:32:06.66784+00
f4b23b5a-7934-4db6-b16f-4c55c926cb7d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	07633e84-d78c-4277-a497-dc062bbb5de7	null	{"name": "Couscous + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 14:32:06.915885+00	2026-10-06 14:32:06.915899+00
c500e049-9a82-40c6-840d-bcb591298749	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	63b3636c-1297-4a04-8acd-b69b5ea50e2f	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-06 14:33:57.716376+00	2026-10-06 14:33:57.716391+00
3dfe15d4-f4cf-47d6-bc03-0498f5e1a9bd	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	b916d44e-3cc3-4656-99e0-ea6086f708a9	null	{"order_id": "b61f47d3-6a41-4cbb-bc0c-84fcc09036f5", "amount_xof": 13500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-06 11:30:14.520756+00	2026-10-06 11:30:14.520768+00
e79465e4-4f9c-4cb9-ac77-9547e315a081	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd	null	{"order_number": "2026-10-06-0004", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-06 12:02:40.665126+00	2026-10-06 12:02:40.665138+00
625814a0-17fd-459b-9b10-dcb6aa300aa8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	null	{"order_number": "2026-10-06-0005", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "guests_count": 4}	\N	caisse-01	\N	2026-10-06 14:30:35.20466+00	2026-10-06 14:30:35.204671+00
92b8ecc9-bec1-4f2c-8090-44db78eae241	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a7085b71-0070-462e-b7a0-15ede34cfb7a	null	{"name": "Atti\\u00e9k\\u00e9 + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-06 14:30:35.501878+00	2026-10-06 14:30:35.501891+00
641f83ff-ff5a-44a9-878c-5b42c4f7019d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	5c853bf0-1866-4f88-a27d-f1fb5caca8f6	null	{"order_number": "2026-10-06-0006", "table_id": "6cf24b95-3c1e-473d-bdd8-2f22c321b558", "guests_count": 4}	\N	caisse-01	\N	2026-10-06 14:31:30.767381+00	2026-10-06 14:31:30.767392+00
f198a4d6-4a82-4c4e-9dd6-edd4e71c96d9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	7f69875d-186d-4540-bb1e-9cd0131738b6	null	{"name": "Yassa + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 14:31:31.08035+00	2026-10-06 14:31:31.080362+00
4d58e728-4ca2-4ffc-89d3-7b135111b16c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d6a13999-ab40-41aa-8d60-10335f230de1	null	{"name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-06 14:31:31.159745+00	2026-10-06 14:31:31.159757+00
0c761d2d-5e04-48b9-9c68-11e5bac5c4f7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	5c56d6c6-70f9-4dc5-9ec1-dcc68f39cb50	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-06 14:32:06.484937+00	2026-10-06 14:32:06.484948+00
34d3e482-5d19-4004-ba29-7dc363555668	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	10dc03af-0cf2-4220-a739-d794065840f6	null	{"name": "Couscous + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-06 14:32:06.834111+00	2026-10-06 14:32:06.834125+00
d4ae0641-3ec7-4918-b5da-83db6a7c0227	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	03a3357b-8fe5-4e51-a2a4-02facf51ed25	null	{"name": "Yassa + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-06 14:33:57.817668+00	2026-10-06 14:33:57.817679+00
14bebd3d-54e8-4950-bf93-399a3a66ac40	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 14:38:31.596894+00	2026-10-06 14:38:31.59691+00
de49d56c-1ff8-415b-aac4-1ae86951d432	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	0df2ee1f-8933-4df2-b36e-febf38bc4465	null	{"order_id": "1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2", "template": "B2B"}	\N	\N	\N	2026-10-06 14:40:00.185696+00	2026-10-06 14:40:00.185705+00
96d02dfd-c33c-4c2a-a09d-658603b9bc39	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	a1634473-271f-443f-a6b0-30130d12effa	null	{"order_id": "4dca0121-6712-4315-8098-c7cb86dad49d", "amount_xof": 7000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-06 11:53:49.427445+00	2026-10-06 11:53:49.427453+00
d2d51c8f-f2e8-4ba6-9948-6541d15041b3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d331d990-5f16-43ef-bd75-042e2fc1f648	null	{"name": "Alloco + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 12:02:40.872508+00	2026-10-06 12:02:40.87252+00
2d39cbda-379b-4e88-9523-d328a0307878	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	8b700a71-4528-4588-9a29-7d4ba886e8ed	null	{"order_id": "c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd", "amount_xof": 15500, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-06 14:28:45.46131+00	2026-10-06 14:28:45.46132+00
20f8616c-9b21-4623-a11d-07f581fbd668	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1e2f199b-a75c-4148-9eb7-a794f5877018	null	{"name": "Frites + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-06 14:30:35.441928+00	2026-10-06 14:30:35.441938+00
5242f02c-d3a2-4574-ba40-2ce8e3d562e1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1acb0446-8b20-4362-8689-b8c96f82d926	null	{"name": "Frites + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-06 14:32:06.575623+00	2026-10-06 14:32:06.575635+00
1f6abd8d-a0fc-4d6e-8b43-ab0c37f8ac74	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	5354ee5e-ddfd-455a-81a9-bc5c48efdd40	null	{"name": "Yassa + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 14:33:57.773375+00	2026-10-06 14:33:57.773386+00
b7900f8d-4b85-4425-9c3e-7079c27ecc25	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	dee46df9-b970-409f-bcea-1555176e82f4	null	{"order_id": "1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2", "amount_xof": 17500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-06 14:40:00.965366+00	2026-10-06 14:40:00.965376+00
9495a47d-4464-408c-a9f9-deefc277eed0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 14:49:48.003655+00	2026-10-06 14:49:48.003664+00
e93093bc-d1d8-4e3c-8eb2-c3d3ca5eaed1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9102aa41-6288-4462-b8ab-4001a433877f	null	{"name": "Frites + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-06 12:02:40.811028+00	2026-10-06 12:02:40.811041+00
903586b3-42ba-4ee5-b27a-2ba6e6c83bf0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	98e6917a-0cec-4e13-bd49-e692079ce347	null	{"name": "Alloco + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-06 12:02:40.940342+00	2026-10-06 12:02:40.940355+00
59cd56bf-d7b3-4355-b0dd-799f959e3236	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	5b81f0aa-9c71-4d3f-9632-8c4f07aff1ba	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-06 14:30:35.371804+00	2026-10-06 14:30:35.371815+00
c263d004-1f36-4684-b818-5dbb72ddb5e2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	2bccabcc-71db-459c-b58c-963db731da21	null	{"name": "Kabato Lafri + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 14:31:30.945047+00	2026-10-06 14:31:30.945057+00
3e52d71a-6ad5-4e4c-baae-02c67d5507b1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	12b14d3e-043e-4753-92e5-9cb1b07895da	null	{"name": "Passion", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-06 14:31:31.022806+00	2026-10-06 14:31:31.022861+00
894f0fa6-3aaa-4088-bc1e-2e31ce01a476	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	null	{"order_number": "2026-10-06-0007", "table_id": "05aa9ad5-594d-4926-8d1a-508eec179caf", "guests_count": 4}	\N	caisse-01	\N	2026-10-06 14:32:06.424256+00	2026-10-06 14:32:06.424269+00
578a11c8-926e-4cdf-91f0-0b6108d61a46	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	db49c978-9039-4280-9fb2-9ba9b1839259	null	{"name": "Atti\\u00e9k\\u00e9 + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-06 14:32:06.738782+00	2026-10-06 14:32:06.738792+00
99e7b403-8132-43de-bf9a-66a813d7d6e4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	64526137-92a1-418d-9d03-6393030d1f1f	null	{"order_number": "2026-10-06-0008", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-06 14:33:57.600554+00	2026-10-06 14:33:57.600568+00
c6b3a465-0712-45be-ba2d-855889132c0e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	0df2ee1f-8933-4df2-b36e-febf38bc4465	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000006", "attempts": 1}	\N	\N	\N	2026-10-06 14:40:00.756906+00	2026-10-06 14:40:00.756916+00
d299041e-7267-446c-bfe7-2d2e48fbca11	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 14:56:23.298607+00	2026-10-06 14:56:23.298615+00
64a0b560-542d-42e6-b93a-75044b706560	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 15:08:40.647838+00	2026-10-06 15:08:40.647848+00
ea909aca-c745-4660-92f2-ea0280eba3d8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	fccf036d-3005-4f99-870f-c6680aaf2a31	null	{"order_id": "64526137-92a1-418d-9d03-6393030d1f1f", "amount_xof": 9500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-06 15:08:58.036653+00	2026-10-06 15:08:58.036664+00
741b6652-d14f-41d7-8d5b-248428258c7c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	761b7ef5-f574-43d1-9038-bc5b0eeadcb4	null	{"order_id": "b3149ccf-0f04-4a5c-8ff9-5aad99d0a137", "amount_xof": 14500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-06 15:10:01.295337+00	2026-10-06 15:10:01.295346+00
5a97cef8-9458-4e54-9ca4-6dffb2d3e443	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 15:13:20.218606+00	2026-10-06 15:13:20.218616+00
6ca57980-e4d0-4d44-9597-2e595da18159	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 15:15:43.47919+00	2026-10-06 15:15:43.479198+00
7273f2ae-8c26-4216-b573-b7d63c0cd389	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0b5fbcdc-9fff-458a-a007-8790bfeadfd5	null	{"name": "Kabato Lafri + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 15:19:59.592954+00	2026-10-06 15:19:59.592962+00
c75f9495-def4-45ef-8829-299bcb5bbf20	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d20fcd9b-d2a4-4dd4-8b89-c5acf2abe30c	null	{"name": "Kabato Lafri + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 15:20:57.461184+00	2026-10-06 15:20:57.461195+00
3dccf39a-9cc0-40cf-a9cb-1240df34b375	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-06 15:34:38.24574+00	2026-10-06 15:34:38.245755+00
1348ac51-c849-46f9-8c54-7581038787fc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d753772c-3739-4002-aaeb-a760b062b921	null	{"name": "Kabato Lafri + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-06 15:34:56.71475+00	2026-10-06 15:34:56.714759+00
03425453-1340-46d4-a633-a6e9155ebb0a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	80c86750-432c-4a02-8355-3ca68d64ab1c	null	{"order_id": "0518ad5e-03a6-4c5a-9636-b9d33da54b4d", "template": "B2B"}	\N	\N	\N	2026-10-06 15:36:22.226701+00	2026-10-06 15:36:22.226711+00
e57b40fc-fd35-4f64-a8f8-73bca8d95820	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	80c86750-432c-4a02-8355-3ca68d64ab1c	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000007", "attempts": 1}	\N	\N	\N	2026-10-06 15:36:22.772962+00	2026-10-06 15:36:22.772969+00
7163ca42-8684-4b6a-b402-dc72ec1fa49a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	544d8200-4a3d-43c1-80c1-45d37ea95f5a	null	{"order_id": "0518ad5e-03a6-4c5a-9636-b9d33da54b4d", "amount_xof": 15500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-06 15:36:23.071067+00	2026-10-06 15:36:23.071075+00
f7ba1fe5-e33e-41b4-b270-6ae3a97302e7	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-06 15:37:08.528811+00	2026-10-06 15:37:08.528819+00
0f029730-6fd3-4684-a714-152fee2724d2	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-06 15:37:14.20859+00	2026-10-06 15:37:14.208597+00
3d1b99ce-ad5a-4acb-9a8a-11b677e91dc9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	2abfb1c6-924f-4ca4-b42a-828add61ceff	null	{"order_id": "5c853bf0-1866-4f88-a27d-f1fb5caca8f6", "amount_xof": 14500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-06 15:38:05.546175+00	2026-10-06 15:38:05.546188+00
da0e2862-0b01-483d-9541-c20c04825370	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	61245d2f-8301-4acc-a965-12f74778b946	null	{"z_number": 1, "counted_cash_xof": 142000, "expected_cash_xof": 142000, "variance_xof": 0}	\N	caisse-01	\N	2026-10-06 15:40:31.983731+00	2026-10-06 15:40:31.98374+00
ed488978-379a-4cdd-9e91-301e29cd4634	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	Z_REPORT_PRINTED	CASH_SESSION	61245d2f-8301-4acc-a965-12f74778b946	null	{"print_job_id": "5e3d2c46-28e4-4b5f-bc07-080f494e48a9", "z_number": 1}	\N	caisse-01	\N	2026-10-06 15:40:40.430371+00	2026-10-06 15:40:40.430382+00
b83f77c9-45d7-4388-a0e5-6e68d5db616a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 10:34:08.919057+00	2026-10-08 10:34:08.919065+00
4231cd16-7e8a-4dbe-abc1-de03cd92c79d	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-08 10:34:24.40831+00	2026-10-08 10:34:24.408318+00
b829afbd-b550-4179-bb91-d59eee8e5d51	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-08 10:40:55.980486+00	2026-10-08 10:40:55.980494+00
eba38015-2f42-4dee-9f65-81c102a1998d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	bec954fb-ce8e-4e82-b546-abecd853d1ac	null	{"opening_float_xof": 50000, "business_date": "2026-10-08"}	\N	caisse-01	\N	2026-10-08 10:44:25.703851+00	2026-10-08 10:44:25.703862+00
194cc8ff-bae9-474f-a66d-4da382c4cc97	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	59e7f907-ab20-43a4-af17-ecbb8ec44f25	null	{"name": "Atti\\u00e9k\\u00e9 + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-08 10:45:03.456659+00	2026-10-08 10:45:03.456667+00
251230ee-d5d8-4daa-a88c-6df027fb67fe	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	9053909f-a781-4609-9174-1e986810c412	null	{"order_id": "c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a", "amount_xof": 8000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-08 10:47:49.097303+00	2026-10-08 10:47:49.097312+00
72dcea34-9509-4447-97ae-590203fdfe20	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	446300e4-108f-4fb9-a437-295aa8a7627b	null	{"name": "Igname bouillie + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-08 10:50:30.305431+00	2026-10-08 10:50:30.305441+00
11b2666e-26b5-414a-b5df-687cfeca2d69	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	565c9e2f-e823-45be-8088-2dc9868add27	null	{"order_id": "21a1947c-5da6-4a14-ae3f-a931b866bb53", "template": "B2B"}	\N	\N	\N	2026-10-08 11:16:20.858894+00	2026-10-08 11:16:20.858904+00
a06a9943-b264-4589-8a46-68cd0d1c8e65	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	7df54088-a227-45bc-911c-3973785c2ccf	null	{"order_number": "2026-10-08-0001", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "guests_count": 4}	\N	caisse-01	\N	2026-10-08 10:45:02.700766+00	2026-10-08 10:45:02.700775+00
33dfb63a-3c3f-464f-8046-8d4f13e59c02	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	76a10d73-2056-47a4-ac1a-763448e4f5d4	null	{"name": "Kabato Kope + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 10:45:02.884765+00	2026-10-08 10:45:02.884776+00
5f1771b3-16ff-487a-92f8-70d01bec72d2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a	null	{"order_number": "2026-10-08-0002", "table_id": "05aa9ad5-594d-4926-8d1a-508eec179caf", "guests_count": 4}	\N	caisse-01	\N	2026-10-08 10:47:29.01226+00	2026-10-08 10:47:29.012269+00
5519bcee-8b91-4cfc-a000-8b2d9d5c0ca3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6a012ac6-a11e-4498-ad81-f49f56185f2d	null	{"name": "Couscous + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-08 10:47:29.109989+00	2026-10-08 10:47:29.109999+00
29351e6d-28d4-4d0b-8b57-8fb3150b2fc6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6bdac272-78d7-454e-88c9-8bbe5384fffa	null	{"name": "D\\u00e9gu\\u00e9", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 10:47:29.482847+00	2026-10-08 10:47:29.482855+00
19656ed5-028b-4f50-a3f5-72031bc6a1ed	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	21a1947c-5da6-4a14-ae3f-a931b866bb53	null	{"order_number": "2026-10-08-0003", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-08 10:50:30.019872+00	2026-10-08 10:50:30.01988+00
120ab69b-56b7-4381-9378-67aabf666f18	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c2128174-33e6-43f8-b066-70fbf44d2a26	null	{"name": "Kabato Lafri + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 10:50:30.117456+00	2026-10-08 10:50:30.117465+00
9268bce6-7bdc-40bb-ab3f-f2388a8b2ba9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 10:55:47.384134+00	2026-10-08 10:55:47.384142+00
ab328d95-ea03-4e9b-9f65-011efa590ee2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:02:22.57545+00	2026-10-08 11:02:22.575459+00
5e54d6ca-5182-419a-85a8-08af488728e0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:15:04.761329+00	2026-10-08 11:15:04.76134+00
8b6f698d-3c2f-42cb-8080-99f2ed89fccc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	565c9e2f-e823-45be-8088-2dc9868add27	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000008", "attempts": 1}	\N	\N	\N	2026-10-08 11:16:21.44983+00	2026-10-08 11:16:21.449836+00
b54144f8-30c9-43ed-8da6-f68cd5cb7c6c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a6786e17-b4f3-4580-92be-844efc770b26	null	{"name": "Kabato Lafri + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 11:19:06.074971+00	2026-10-08 11:19:06.074981+00
f1d46bec-7245-4232-993f-bca8a4b1a6b4	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:27:55.99208+00	2026-10-08 11:27:55.992089+00
a5fc2e5f-5b8c-47ed-9c10-c8f0ab603564	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:32:44.153683+00	2026-10-08 11:32:44.153692+00
d8078883-5060-4414-aa56-3da783098000	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	68eb6a81-cbac-48aa-9faa-17a088a2de3a	null	{"name": "Kabato Dah + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-08 10:45:03.072894+00	2026-10-08 10:45:03.072904+00
4b8185ab-8ba3-46ea-b2bf-663449092f33	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	7fd25ebc-b316-4bfc-bee1-670b4309949b	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 10:45:03.361016+00	2026-10-08 10:45:03.361024+00
eea2d6fd-67bb-485d-aeb6-fc832b52c108	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6019f375-ed4a-4fa6-8512-8ba216d4305d	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 10:50:30.207485+00	2026-10-08 10:50:30.207493+00
a81deb42-1805-44ba-b301-0c650566b016	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 10:59:18.992418+00	2026-10-08 10:59:18.992425+00
fa1b7587-a689-4678-87ce-991009b1113c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:34:36.898056+00	2026-10-08 11:34:36.898067+00
09d17152-3032-49e7-83e4-3c2e98c98a97	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	2d2a6e7a-5907-4bb1-bdf9-b4316cdf980e	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 10:45:03.177797+00	2026-10-08 10:45:03.17783+00
683187fe-2a2f-4e30-90b5-0b6a1dad54f5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:06:01.209235+00	2026-10-08 11:06:01.209245+00
c15c1e78-df79-4b1f-8515-f6edec5a8f6a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	c3d7318e-8e10-445c-b614-32f462361cde	null	{"order_number": "2026-10-08-0004", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-08 11:19:05.921109+00	2026-10-08 11:19:05.921118+00
f762d1b3-01ed-4614-b3a3-16a68bad4941	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6e469212-ece0-4f33-826c-5d24b415991f	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 11:19:34.378051+00	2026-10-08 11:19:34.37806+00
2228aa7f-d918-4260-9fed-2f85ee53ec85	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	aa4c4b73-4396-4c1c-bd57-1e21cd753451	null	{"name": "Passion", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 11:19:34.49967+00	2026-10-08 11:19:34.499679+00
f968bf92-e936-40ed-8508-ed5fc1c90d6a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	47ac6cc4-44e2-48e0-91ab-1a4b02ee8b9b	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 10:45:03.272687+00	2026-10-08 10:45:03.272696+00
1879c251-5248-4388-a05d-430ee72b4281	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a4b93ba1-fee7-4204-8d95-748975e2190a	null	{"name": "Couscous + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 10:47:29.287203+00	2026-10-08 10:47:29.287212+00
9871e0f4-1126-4d2e-9c3f-01f48e67c5fc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	20e66ef5-9387-41b4-9db6-6542a6c89df3	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 10:47:29.390093+00	2026-10-08 10:47:29.390101+00
c93ea8c1-c2ff-41c4-b801-d7b06d6b94ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	b86016a3-57a4-4d79-8a82-92349aad5825	null	{"order_id": "21a1947c-5da6-4a14-ae3f-a931b866bb53", "amount_xof": 8000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-08 11:16:21.940493+00	2026-10-08 11:16:21.940503+00
e35ab57a-c5e3-4a2c-9108-e3d3f48505cc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:24:39.656413+00	2026-10-08 11:24:39.656421+00
7f9fba0f-0327-4e55-817b-8501380052f8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:44:08.842067+00	2026-10-08 11:44:08.842075+00
104c8b15-8996-4cde-a6ef-43acfb083676	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:45:09.2374+00	2026-10-08 11:45:09.23741+00
389e7662-9085-4e8c-be2e-f72c784b69a5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:50:37.116357+00	2026-10-08 11:50:37.116374+00
4f19c99a-74fc-41ab-b8b1-8e0ffb557c34	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:50:51.555934+00	2026-10-08 11:50:51.55594+00
5197f767-2f06-473b-b327-7bd74874bcbb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	24cdb8f7-9634-4224-a8d3-c5446ec0c315	null	{"order_number": "2026-10-08-0005", "table_id": "05aa9ad5-594d-4926-8d1a-508eec179caf", "guests_count": 4}	\N	caisse-01	\N	2026-10-08 11:51:53.566723+00	2026-10-08 11:51:53.566732+00
c5e2291b-5261-4b27-be52-4dc9c5bcfb5b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	da276ec4-5d4a-42ab-82c1-95f509b45c57	null	{"name": "Tamarin", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 11:51:53.747757+00	2026-10-08 11:51:53.747767+00
ab720488-d5ee-4aa6-96b4-8678afb7fd28	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ccd5eaec-5db6-47b8-a11f-54579449f5e7	null	{"name": "Atti\\u00e9k\\u00e9 + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 11:51:54.015762+00	2026-10-08 11:51:54.015772+00
ed481a24-b069-48b0-9eb6-f43245a4296b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	61c4b598-5eca-40c9-bbde-5ce224cc09fd	null	{"name": "Bissap", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 11:51:54.220389+00	2026-10-08 11:51:54.220399+00
bb58432b-8853-4660-bab0-fd2e70d92ef1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	20fc4675-1dfa-4c2e-9582-f124d7f23b71	null	{"name": "Frites + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 11:51:54.425831+00	2026-10-08 11:51:54.425843+00
adf1288c-712a-4ebf-910b-f2b851005a31	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a81aa48a-0164-4340-af4b-be25350abda4	null	{"name": "Sauce L\\u00e9gume + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 11:51:54.592861+00	2026-10-08 11:51:54.592868+00
58995006-d1f1-4aff-8ffe-4b5ebca75b09	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	51082073-382f-4039-a9d2-428ff46a8045	null	{"name": "Sauce Feuille + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 11:51:54.776246+00	2026-10-08 11:51:54.776266+00
ea07f7f8-13bb-40ea-a826-04abd7c926f0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	1581e5e9-617b-4796-95bd-5346f318e837	null	{"order_number": "2026-10-08-0006", "table_id": "6cf24b95-3c1e-473d-bdd8-2f22c321b558", "guests_count": 4}	\N	caisse-01	\N	2026-10-08 11:52:22.389945+00	2026-10-08 11:52:22.389956+00
59c84c4b-5ae0-44bd-9f76-1124a3dbadbc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	67ae54f0-b959-4f6e-a52f-78e00b91c34a	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 11:52:22.534642+00	2026-10-08 11:52:22.534651+00
960d3741-767c-4ae0-b53d-2d27c6a2cd09	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1edea5f7-5afc-488d-91b5-eed01f26acac	null	{"name": "Yassa + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 11:52:22.752604+00	2026-10-08 11:52:22.752616+00
d3e1e30d-0e52-4cb3-a5df-bceb6c79b9c8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9b1897a7-1cfc-4ed3-9671-62140524c852	null	{"name": "Tchep + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 11:52:22.921081+00	2026-10-08 11:52:22.921093+00
500cc029-5886-4682-9f35-4f6dcd3bee6a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	828ab928-5624-4979-b2ff-db03e3807b6b	null	{"name": "Yassa + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 11:52:23.05664+00	2026-10-08 11:52:23.056651+00
eddf2ae8-3e6e-41ca-bd71-5d5fc5d3261d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ab837e0a-a0d7-4cf0-8a67-71da2fbbf9de	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 11:52:23.222757+00	2026-10-08 11:52:23.222769+00
c837e3cd-2d0d-40bf-b552-2e8d5183d98c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	257c0c77-2c1b-4572-b2a2-0c53fafc2f02	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 11:52:23.368009+00	2026-10-08 11:52:23.368019+00
206a2e76-873b-43a8-8bc9-27428354d954	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c4d6976c-02a0-4899-908e-792cc4862d34	null	{"name": "Passion", "quantity": 2, "line_total_xof": 2000}	\N	caisse-01	\N	2026-10-08 11:52:23.531785+00	2026-10-08 11:52:23.533882+00
ca2ce55f-d0ab-432b-86a3-6d65827b4800	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 11:59:47.597019+00	2026-10-08 11:59:47.597034+00
30395176-bfba-4230-bf8a-e13c27681f8d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 12:05:25.137291+00	2026-10-08 12:05:25.137303+00
83bc912a-6b8f-4890-825e-828dc3dd09d5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 12:10:57.332713+00	2026-10-08 12:10:57.332737+00
30f43050-d853-46df-8aea-415db77e5928	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 12:15:17.28593+00	2026-10-08 12:15:17.28594+00
b8c4b3a4-daaf-4266-aca1-be21887930a4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	pos-1	127.0.0.1	2026-10-08 12:16:31.665322+00	2026-10-08 12:16:31.665332+00
26b65cf4-db8f-4e4f-95df-151ab7d5a0bc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	pos-1	127.0.0.1	2026-10-08 12:18:21.777671+00	2026-10-08 12:18:21.77768+00
2e6c5bfd-4653-4064-962d-ea4feff16f44	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 12:18:58.470575+00	2026-10-08 12:18:58.470586+00
555ca120-44f7-4831-b76f-e886eb189f92	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 14:16:41.739987+00	2026-10-08 14:16:41.740001+00
46fb5038-b167-4b32-8235-169f2794c3ef	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 14:16:49.743799+00	2026-10-08 14:16:49.743845+00
cebd84fb-ed90-4798-ae49-f0952a06c779	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-08 14:19:35.949702+00	2026-10-08 14:19:35.94971+00
02062964-41f6-44ea-ba8c-40e59d6d0f1f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	1d103862-dec9-4695-9f8e-c697a5a63bad	null	{"order_number": "2026-10-08-0004", "table_id": null, "guests_count": 1}	\N	test-device	\N	2026-10-08 14:29:16.178088+00	2026-10-08 14:29:16.178098+00
1e2bbf00-c273-4917-9d23-be05826e75a3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 14:30:38.842527+00	2026-10-08 14:30:38.842639+00
e95b1e41-a65e-4f0f-a8ca-ae161821d0da	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	e6ff5588-1a97-409f-b651-8dcd1ec5135b	null	{"order_number": "2026-10-08-0004", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "guests_count": 4}	\N	caisse-01	\N	2026-10-08 14:33:50.614338+00	2026-10-08 14:33:50.614351+00
74a0b24e-3d10-4a5a-bc51-ffe8b083efec	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a875f631-1aad-41ac-b5ef-d4e9e8b5116b	null	{"name": "Kabato Dah + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:33:50.963768+00	2026-10-08 14:33:50.963781+00
f6477e69-d39e-41a5-9a50-9149eade2e30	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	151ad44b-07ca-4c27-a654-0323faa9847b	null	{"name": "Kabato Dah + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 14:33:51.190367+00	2026-10-08 14:33:51.190378+00
eead0982-904d-4920-b178-88c794180573	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4378c8a6-422e-4960-9b3b-2ac2b0b1a352	null	{"name": "Kabato Kope + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 14:33:51.411422+00	2026-10-08 14:33:51.411433+00
b14c1274-b849-448e-9705-87efa01fbc09	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e3fab71b-b539-4ba7-bb7d-7dbcab053644	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 14:33:51.603288+00	2026-10-08 14:33:51.603298+00
44776a71-6ac3-4e71-b8d3-f07cc32bc87a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	93692203-4e85-4e26-b2d5-a5e8308eed51	null	{"name": "Bissap", "quantity": 3, "line_total_xof": 1500}	\N	caisse-01	\N	2026-10-08 14:33:51.799687+00	2026-10-08 14:33:51.799696+00
03dec33c-1240-4d24-93ad-c229c9e3e720	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	1ae79c99-2c11-40f4-9b4e-6948b5256aed	null	{"order_number": "2026-10-08-0005", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-08 14:36:02.133228+00	2026-10-08 14:36:02.133237+00
509c6755-90b7-48c7-899d-df212b0709d8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	46e136ee-bbf7-4b07-943e-2e3977562cf6	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:36:02.33547+00	2026-10-08 14:36:02.335479+00
7b19b9c8-c42f-4392-8199-039179fae3de	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c77bbda0-02d1-406b-8574-635b5f91e893	null	{"name": "Atti\\u00e9k\\u00e9 + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:36:02.482717+00	2026-10-08 14:36:02.482726+00
acd0c143-b2c1-4df3-947f-6a47c973cb93	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a6b0a7ef-5441-4612-8bff-481292fa3917	null	{"name": "Igname frite + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-08 14:36:02.631961+00	2026-10-08 14:36:02.631968+00
da811f6a-4581-44fa-befa-67dec9dedacf	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	34ae8946-65cb-4182-a54b-cb1da219dd5b	null	{"name": "Alloco + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:36:02.78944+00	2026-10-08 14:36:02.789449+00
e0b36370-abcc-43dc-97fb-90e5dcc2ad26	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6db34d42-4166-4d91-9cab-5975584a5ab6	null	{"name": "D\\u00e9gu\\u00e9", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:36:02.924778+00	2026-10-08 14:36:02.924796+00
37f1bab0-45a2-4d49-8f70-5ede67bb5e06	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a3fd6878-a50a-4a7b-88b3-6fa9b14945e0	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 14:36:03.053945+00	2026-10-08 14:36:03.053956+00
9229244c-9c4f-4403-b9db-061d42a12a95	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	7ce53cf8-fbfd-4792-8ed2-e96b388a31c6	null	{"name": "Lait", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:36:03.171556+00	2026-10-08 14:36:03.171687+00
d86cd4e5-5cdd-4cb5-acc3-a5c73573257e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1702ffc1-934d-4b8b-acfc-7e72de785bf5	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 14:36:03.328155+00	2026-10-08 14:36:03.328165+00
336d3607-859b-4f58-b791-5ba5ca177002	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	93069097-ee32-4d2c-a7c1-efbc6471764c	null	{"name": "Passion", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:36:03.473958+00	2026-10-08 14:36:03.473969+00
7874abed-58d0-4f68-bc29-a8be8242d915	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	16f28926-701a-443d-8ca1-d7203764e656	null	{"name": "Bissap", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:36:03.622598+00	2026-10-08 14:36:03.622614+00
c354c03e-4de2-4e77-ac58-974fb21813aa	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	076109cb-177f-408e-b8d2-1a2ca7c82b9b	null	{"order_number": "2026-10-08-0006", "table_id": "6cf24b95-3c1e-473d-bdd8-2f22c321b558", "guests_count": 4}	\N	caisse-01	\N	2026-10-08 14:37:16.004142+00	2026-10-08 14:37:16.004151+00
d5b19a5b-b404-4474-beb1-99cd6317efb6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	7dc13855-7de9-4d1b-bd32-406c6386193b	null	{"name": "Couscous + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:37:16.18734+00	2026-10-08 14:37:16.18735+00
b043056f-0d8f-42ab-ba96-dcef39537d11	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3838d2b9-a2c3-4be1-a44b-9fa1e5d35d5f	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-08 14:37:16.425712+00	2026-10-08 14:37:16.425728+00
be6ff808-bf83-41f7-9aec-77d08c611be9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	172c9b9c-6e6b-4ea7-ad32-2b8e0b2e0e0d	null	{"name": "Atti\\u00e9k\\u00e9 + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:37:16.600693+00	2026-10-08 14:37:16.600702+00
2d1f751f-ea4f-45d0-9451-242d83dc18b7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0e8cdaed-940b-44fc-8f50-9c63815b427f	null	{"name": "Sauce L\\u00e9gume + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:37:16.738515+00	2026-10-08 14:37:16.738524+00
705ae296-a87f-40b8-bdd1-4fb29a8fe878	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	321a6a73-49ee-4968-8075-e3b02ade0c05	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 14:37:16.902313+00	2026-10-08 14:37:16.902321+00
13ee604d-1345-45ee-bc1e-98bca255767d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a8e09b2d-fb2a-4d80-bc1a-4f90b7e0c5e4	null	{"name": "D\\u00e9gu\\u00e9", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:37:17.07065+00	2026-10-08 14:37:17.070668+00
fc49339b-ced3-4e9d-adcb-bfc464edc27b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b86e5341-4687-4c46-ac9f-9b8663251295	null	{"name": "Lait", "quantity": 2, "line_total_xof": 2000}	\N	caisse-01	\N	2026-10-08 14:37:17.234111+00	2026-10-08 14:37:17.23412+00
3fa23a89-343f-4f37-ad00-19ddfd2f3302	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4582e8fd-ac08-465b-89ca-cf65df2ee94b	null	{"name": "Tamarin", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:37:17.356374+00	2026-10-08 14:37:17.356386+00
bbd3def7-ceb6-4d0c-a5bb-813024b2334e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 12:05:24.117286+00	2026-10-13 12:05:24.117298+00
25e0ae96-7270-4fd5-ba46-705844df3d70	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	08afc7a2-f305-46c9-9aa8-3ae565bf418b	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 14:37:17.583756+00	2026-10-08 14:37:17.583764+00
5cbf3362-4a2d-4230-9bde-162434b473d1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4edefae4-f94d-4d6b-ab33-2e13d82138cf	null	{"name": "Bissap", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:43:09.011947+00	2026-10-08 14:43:09.011957+00
ac54d8f4-e72f-4d65-8744-e8676bf4ead3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:43:00.069873+00	2026-10-08 15:43:00.069887+00
f1879d14-6ca6-4b3b-961e-4749edbeb885	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:43:12.105483+00	2026-10-08 15:43:12.105493+00
9a8ce62b-c6ba-4622-95f9-649accb23895	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	de9cdf62-6ffc-4901-a1d1-5ab8a6f6a1f7	null	{"name": "Passion", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:37:17.798588+00	2026-10-08 14:37:17.798602+00
c4a580c8-8edd-4989-b5f8-26b0d6815dd6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	db5be098-d0bf-42f8-91e8-9a1ecd858825	null	{"order_number": "2026-10-08-0007", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-08 14:43:08.399787+00	2026-10-08 14:43:08.399798+00
62e64de7-f076-4e8a-8952-4802772e0768	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	dbfbf622-5181-4cd8-a9cd-e102bb1ed558	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:43:08.586112+00	2026-10-08 14:43:08.586128+00
518bb540-8b3c-49ea-a3e0-3baba5c3b755	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	814de8e4-3ffa-4c6d-a0ac-4ab8eb68a6ea	null	{"name": "Tamarin", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-08 14:43:08.880856+00	2026-10-08 14:43:08.880867+00
39a1da76-8117-4a38-9100-61c1d3056918	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	926e5779-7412-40bf-83ab-b6da6630b40e	null	{"order_id": "1ae79c99-2c11-40f4-9b4e-6948b5256aed", "template": "B2B"}	\N	\N	\N	2026-10-08 14:46:12.452963+00	2026-10-08 14:46:12.452974+00
64d6484a-103c-4ab3-b339-56d609238c7a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:04:00.882436+00	2026-10-08 15:04:00.882446+00
8347b0d8-5272-4725-85f3-2bb05b616901	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	9a9fc6d5-9fb0-4031-929e-50035995d1db	null	{"order_number": "2026-10-08-0008", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-08 15:04:46.450715+00	2026-10-08 15:04:46.450726+00
92d8fc5b-9f49-4aef-9131-4c2b2b800c09	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	dfb0d182-a56c-46e8-860a-d52410f695c6	null	{"order_id": "076109cb-177f-408e-b8d2-1a2ca7c82b9b", "amount_xof": 17000, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-08 15:07:18.375593+00	2026-10-08 15:07:18.375603+00
40eb87a3-7df0-4c0d-bc3b-4b775703aab3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:08:11.090073+00	2026-10-08 15:08:11.090081+00
ea01853f-12aa-4b0b-be22-e30ef89184f4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	a00c63dd-ab30-477f-a178-d05915f28023	null	{"order_id": "e6ff5588-1a97-409f-b651-8dcd1ec5135b", "template": "B2C"}	\N	\N	\N	2026-10-08 15:13:44.490882+00	2026-10-08 15:13:44.490895+00
960c6fc4-94e7-4f0f-a64f-3fc054338207	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	a00c63dd-ab30-477f-a178-d05915f28023	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000010", "attempts": 1}	\N	\N	\N	2026-10-08 15:13:45.093415+00	2026-10-08 15:13:45.093426+00
cf5fd63d-72d1-4def-838b-ec16ecbc6b7e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:43:29.09122+00	2026-10-08 15:43:29.091236+00
400f2d6f-4703-4b9a-a077-a64ce288e791	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	bec954fb-ce8e-4e82-b546-abecd853d1ac	null	{"z_number": 2, "counted_cash_xof": 104000, "expected_cash_xof": 104000, "variance_xof": 0}	\N	caisse-01	\N	2026-10-08 15:44:45.651746+00	2026-10-08 15:44:45.651757+00
71107693-b84b-4ea8-8ba4-51a8959c7bd7	4b5224bf-057a-4654-b13e-0e65ff403161	\N	TEST_TICKET_PRINTED	PRINTER	Xprinter_58	null	{"success": true, "width": 32}	\N	caisse-01	\N	2026-10-08 16:40:24.612492+00	2026-10-08 16:40:24.612501+00
5778b5dd-724d-4152-977a-af0f388ff6c5	4b5224bf-057a-4654-b13e-0e65ff403161	\N	TEST_TICKET_PRINTED	PRINTER	Xprinter_58	null	{"success": true, "width": 32}	\N	caisse-01	\N	2026-10-08 16:40:39.743552+00	2026-10-08 16:40:39.743563+00
83607a41-8643-4183-ba24-d5a613a230e0	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-08 18:41:04.288233+00	2026-10-08 18:41:04.288245+00
6beefa3a-10c7-4ddf-81d5-c38d292a2287	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	bd666ef0-7065-4cf8-b783-8cddd5f984dd	null	{"name": "Atti\\u00e9k\\u00e9 + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 14:43:08.759049+00	2026-10-08 14:43:08.759066+00
6efd963a-db89-47d1-9974-0c6634cc65fb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	91b83a0e-d8d4-48ee-9e5b-6769b4e07e39	null	{"order_id": "db5be098-d0bf-42f8-91e8-9a1ecd858825", "amount_xof": 9000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-08 14:43:57.815289+00	2026-10-08 14:43:57.815298+00
acec3bf6-b0a1-4e93-af26-a0ae9d490aa5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 14:56:35.191211+00	2026-10-08 14:56:35.191223+00
8b646d36-7bc4-4fa5-80fa-e9531ccce275	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	78e58766-d32c-4c2b-a962-b9c37d131f5f	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 15:04:46.81195+00	2026-10-08 15:04:46.811967+00
54f733ec-a00c-44ed-9f69-f1d290fada8e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	6251cc2f-2a4b-41ad-8fb5-74ada8579abc	null	{"order_id": "9a9fc6d5-9fb0-4031-929e-50035995d1db", "amount_xof": 3500, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-08 15:06:00.516485+00	2026-10-08 15:06:00.51649+00
132150f0-0c73-4e26-b2ed-299b9e245f5b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	0336184a-b88c-463d-9ea9-8e7cfae6fce9	null	{"order_id": "867b6c58-13d3-4af8-8f2e-094ae7f69f2c", "amount_xof": 2500, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-08 15:06:41.042594+00	2026-10-08 15:06:41.0426+00
56a6a483-857b-4919-a7be-96fb504777fe	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-08 15:08:05.762361+00	2026-10-08 15:08:05.76237+00
9515fbe2-045d-40ae-9062-c5fb4c0dbc71	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0546e104-6133-4579-92ef-f6747acbf45b	null	{"name": "Passion", "quantity": 2, "line_total_xof": 2000}	\N	caisse-01	\N	2026-10-08 14:43:09.137516+00	2026-10-08 14:43:09.137526+00
d7bb0362-3fff-4656-a5d5-79c917563ccc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	6a6e1813-0825-4c8c-8a7d-06bbf91bdbea	null	{"order_id": "1ae79c99-2c11-40f4-9b4e-6948b5256aed", "amount_xof": 17500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-08 14:46:13.283233+00	2026-10-08 14:46:13.28324+00
c92496c8-b3af-49e1-9e32-a8f8e44f800a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 14:54:12.048759+00	2026-10-08 14:54:12.048768+00
0c5864a4-0081-4a47-a4c0-e53e6217ea03	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	2203f056-5bdb-4db6-860c-ec0098fb976f	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-08 15:04:47.003314+00	2026-10-08 15:04:47.003325+00
d1b4cc09-8c2a-46a2-841e-34b821cedc6e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	867b6c58-13d3-4af8-8f2e-094ae7f69f2c	null	{"order_number": "2026-10-08-0009", "table_id": "d3602f9e-0bc4-4386-8e39-367925cb190a", "guests_count": 4}	\N	caisse-01	\N	2026-10-08 15:05:17.659853+00	2026-10-08 15:05:17.659863+00
6f9b79bb-c759-4f9c-9a9a-50323c244dd1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:12:52.831079+00	2026-10-08 15:12:52.831089+00
e12e3f64-74cb-4eca-b210-ef4e5ae35d69	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:40:31.173006+00	2026-10-08 15:40:31.173156+00
e29723a6-9f4b-4810-b691-c81c043eb54e	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:51:26.805419+00	2026-10-08 15:51:26.805431+00
d6a94f33-0a96-4cfc-85d7-33b9c4dcb80a	4b5224bf-057a-4654-b13e-0e65ff403161	\N	TEST_TICKET_PRINTED	PRINTER	Xprinter_58	null	{"success": true, "width": 32}	\N	caisse-01	\N	2026-10-08 16:39:20.994054+00	2026-10-08 16:39:20.99417+00
861779bf-2c6e-4e76-afb3-5f1b51085e84	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 18:40:44.380746+00	2026-10-08 18:40:44.380761+00
a524853e-7b80-4583-b35a-c0b666a97122	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	534d40ba-7ee4-47ac-93a0-080192232503	null	{"opening_float_xof": 50000, "business_date": "2026-10-13"}	\N	caisse-01	\N	2026-10-13 11:06:39.074786+00	2026-10-13 11:06:39.074799+00
b96044df-d6b9-4c90-af8d-419cadd1230b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	926e5779-7412-40bf-83ab-b6da6630b40e	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000009", "attempts": 1}	\N	\N	\N	2026-10-08 14:46:13.141428+00	2026-10-08 14:46:13.141437+00
d923516a-7e88-4cd6-8f6c-48ff3d593795	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-08 15:00:33.657468+00	2026-10-08 15:00:33.657477+00
11091a2f-b432-4edc-9401-154fa2685977	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	5deace54-8864-44d1-95f5-a6ebe4d39638	null	{"name": "Kabato Kope + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 15:04:46.644501+00	2026-10-08 15:04:46.644513+00
48743f00-05eb-47c7-8d8e-ff1105a6ce0f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b271956a-663e-41e9-8435-751333d9bd6d	null	{"name": "Sauce L\\u00e9gume + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-08 15:05:17.808979+00	2026-10-08 15:05:17.808989+00
534e8b92-56f1-4d4a-b64a-cdb5ffed7ff8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	f87360b3-2919-45b5-9c8f-f0d21ba4c4e1	null	{"order_id": "e6ff5588-1a97-409f-b651-8dcd1ec5135b", "amount_xof": 11500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-08 15:13:45.235771+00	2026-10-08 15:13:45.235776+00
51d3740d-35ed-4233-9669-3a0723237ff8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 11:06:30.735002+00	2026-10-13 11:06:30.735009+00
21f2ad55-e21d-4c36-9a0a-d516146c0f11	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	39bd2f25-6504-419b-b010-af921b9e733a	null	{"order_number": "2026-10-13-0001", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-13 11:09:31.136438+00	2026-10-13 11:09:31.136449+00
986f693b-8e06-473b-9522-0684d15e6e12	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	742c3ee8-ae3e-4a9b-ab92-1d6077871d05	null	{"name": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-13 11:09:31.279917+00	2026-10-13 11:09:31.279932+00
50513691-0c12-453f-aa1e-2684d5ee3270	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	42eb2f06-c5ba-4efe-96f3-6ce14641b0c8	null	{"name": "Salade Panach\\u00e9e + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-13 11:09:31.41678+00	2026-10-13 11:09:31.416789+00
4bf2c2de-f612-4136-b018-5533c0dd4aaf	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	57be927e-2330-43ad-96f1-dea60e4adbdb	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-13 11:09:31.542966+00	2026-10-13 11:09:31.542975+00
ad423ad3-6729-45bc-80a7-f9bdb16619ec	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	fa4f3cd0-29cc-4384-9751-6ef4e7c89ee3	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-13 11:09:31.727196+00	2026-10-13 11:09:31.727209+00
f7be4e91-f72d-4437-8a46-cffd1341863a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 11:19:07.275347+00	2026-10-13 11:19:07.275425+00
9e4e21a6-1b45-475c-9e33-3fdb6782b055	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 11:25:18.5119+00	2026-10-13 11:25:18.511911+00
2a460a60-f606-45bd-81b8-18f780524c6e	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-13 11:25:58.602102+00	2026-10-13 11:25:58.602109+00
2fe6c21f-6ba0-478f-a790-e8de97346e1d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 11:28:51.081557+00	2026-10-13 11:28:51.081564+00
2606be16-6b44-437d-b433-5efc23f27530	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	c7b4ce76-37d6-4963-83b6-5da7c270aa02	null	{"order_number": "2026-10-13-0002", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-13 11:29:12.948865+00	2026-10-13 11:29:12.948876+00
35db1ebc-24a8-4288-8ecb-366babaf3e70	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1f1d6002-b9ff-4446-92e0-5d144050e407	null	{"name": "Sauce Feuille + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-13 11:29:13.085715+00	2026-10-13 11:29:13.085724+00
d79a6c16-17c7-4acf-ac08-e9dbefa83d70	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	f81254a9-7d59-4854-a8c4-fded26287cfd	null	{"name": "Sauce L\\u00e9gume + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-13 11:29:13.188216+00	2026-10-13 11:29:13.188224+00
5e33c115-2544-4b16-94f2-cb6f4bf4aefd	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	135fff4f-cfed-4dee-bb68-00c99c0986eb	null	{"name": "Sauce Dah + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-13 11:29:13.291022+00	2026-10-13 11:29:13.291032+00
32704ca6-5305-4f36-8642-6514f90d0c9b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ab726aff-b107-4730-9b4d-2d2731937b56	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-13 11:29:13.390331+00	2026-10-13 11:29:13.39034+00
0f8a0016-b492-403d-a88b-8a99e7dced1a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	7f941c08-f4bd-43a8-9552-bbf86db49fa3	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-13 11:29:13.483884+00	2026-10-13 11:29:13.483892+00
bc3291a0-5f77-4fdb-bff7-0b6121a10cd8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	null	{"order_number": "2026-10-13-0003", "table_id": "d3602f9e-0bc4-4386-8e39-367925cb190a", "guests_count": 4}	\N	caisse-01	\N	2026-10-13 11:29:47.521763+00	2026-10-13 11:29:47.521772+00
22cab0fb-b972-4ce2-a632-ace2afc1fe87	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d705c9bf-1800-4807-9e10-1788820cf2a4	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-13 11:29:47.62945+00	2026-10-13 11:29:47.629459+00
db883db3-8344-41cc-a548-9abb8c68a6d3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	fe538e79-a17d-4aa4-acce-9d7570ebb5d7	null	{"name": "Alloco + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-13 11:29:47.813712+00	2026-10-13 11:29:47.813722+00
87f7ec9a-cfb6-4117-9e0d-adeda935e627	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4d957ba9-4aa6-4932-abfb-b10ca4211bae	null	{"name": "Atti\\u00e9k\\u00e9 + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-13 11:29:47.997243+00	2026-10-13 11:29:47.997252+00
63485412-30e1-410c-beba-8a57c60d76cb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	863d789a-8cef-41b4-aaec-2d188e547ce5	null	{"name": "Alloco + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-13 11:29:48.105586+00	2026-10-13 11:29:48.105596+00
84232efe-0f49-49f5-b6a3-d63915731416	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3358b33b-c6bd-4848-9c6b-cdbca5cc4750	null	{"name": "Passion", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-13 11:29:48.196257+00	2026-10-13 11:29:48.196265+00
fd7a4475-6816-4db8-9425-d9cb1125f40a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c745a040-3ad3-43d6-9716-ecbbd7a5362a	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-13 11:29:48.292937+00	2026-10-13 11:29:48.292947+00
a7537ff9-0154-4a55-86e7-f0539ec89d15	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 11:55:11.967848+00	2026-10-13 11:55:11.967857+00
b28f02ae-6879-45ef-9aa3-f8c80066f71e	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-13 11:55:33.410728+00	2026-10-13 11:55:33.410738+00
05a2bae4-5380-46fb-8518-ab7c0c683a9f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 12:09:32.12369+00	2026-10-13 12:09:32.123705+00
21d5b3b5-c91c-49bb-8fa2-57706c90e5ce	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 12:19:38.40223+00	2026-10-13 12:19:38.402237+00
25040e40-5bfe-4fbe-82f9-dc914724679e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	60998ea0-4546-437f-bddf-a6ed70c492ca	null	{"order_id": "c7b4ce76-37d6-4963-83b6-5da7c270aa02", "template": "B2B"}	\N	\N	\N	2026-10-13 12:20:41.259982+00	2026-10-13 12:20:41.259994+00
c1886bf7-a133-4799-8ca7-fdf0d1cf5576	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	60998ea0-4546-437f-bddf-a6ed70c492ca	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000011", "attempts": 1}	\N	\N	\N	2026-10-13 12:20:41.660166+00	2026-10-13 12:20:41.660172+00
eda90305-af88-40f3-a7e7-640346983854	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	556b1b9f-3bad-47d0-a487-0879ec2aae3f	null	{"order_id": "c7b4ce76-37d6-4963-83b6-5da7c270aa02", "amount_xof": 10000, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-13 12:20:42.116592+00	2026-10-13 12:20:42.116597+00
8537c286-9d76-474e-bdd2-fa3f1920e9a7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	141a3d65-75fb-4489-9749-d7fcac22031b	null	{"order_id": "39bd2f25-6504-419b-b010-af921b9e733a", "amount_xof": 7500, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-13 12:22:25.240581+00	2026-10-13 12:22:25.240591+00
95a6094e-3bf1-4c74-ba2a-883ca808e692	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	b53715e2-f60d-4478-8013-11270c7e0732	null	{"order_id": "70e4726f-ac39-499c-9e84-97f3ccd8b1d1", "amount_xof": 14000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-13 12:23:48.106739+00	2026-10-13 12:23:48.106749+00
00b83f48-ab66-451c-b11e-5840f6c1b0d7	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-13 12:24:22.053065+00	2026-10-13 12:24:22.053073+00
dd007d32-db94-44f8-8226-bb2f3d98087a	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:38:47.118255+00	2026-10-13 14:38:47.118263+00
45d9413c-b997-4bbc-a090-801e917786a8	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:38:49.343756+00	2026-10-13 14:38:49.343762+00
069fef20-be81-4b2c-b252-5030fcaebb1c	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:38:51.581292+00	2026-10-13 14:38:51.5813+00
0b27a62b-d62a-495d-99fb-169cd1142c9a	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:38:54.132703+00	2026-10-13 14:38:54.132713+00
d5b3ba85-2729-4646-a4e7-63d6fbada94f	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:38:59.278804+00	2026-10-13 14:38:59.278812+00
2be03613-9acf-4404-a9b5-8457fd2d83cf	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:39:01.882916+00	2026-10-13 14:39:01.882924+00
8ada829d-a1da-4952-b9da-b3335f66a1b1	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:39:04.505812+00	2026-10-13 14:39:04.505836+00
1e6fd450-80a5-4bfd-9514-e79741e9845c	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:39:09.325773+00	2026-10-13 14:39:09.325782+00
7ac0ef29-164d-4f8e-ba2c-494d4e9096e2	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:39:11.627094+00	2026-10-13 14:39:11.627103+00
89615e1c-d6cb-47c2-807f-07375177f831	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-13 14:39:13.90077+00	2026-10-13 14:39:13.900779+00
5d9c193a-f20b-40f7-81d3-d73fb337cd5d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 14:49:13.187258+00	2026-10-13 14:49:13.187324+00
48ad8de5-d9f3-49bd-94f7-a9e2bf7668ee	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	e39da534-1326-47b7-a6e2-b3bdccfbd904	null	{"order_number": "2026-10-13-0004", "table_id": "6cf24b95-3c1e-473d-bdd8-2f22c321b558", "guests_count": 4}	\N	caisse-01	\N	2026-10-13 14:51:09.371+00	2026-10-13 14:51:09.37101+00
7cfa2bb6-a11e-414e-8562-86443d7ffb35	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a18a82f7-702b-4064-8732-461c7c043f31	null	{"name": "Kabato Lafri + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-13 14:51:09.524601+00	2026-10-13 14:51:09.524611+00
fd788ea4-d2cd-4a44-b0ee-9bf1fbff97e8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3887aaf8-a5c8-4e05-abbc-b6f9a9d6ab3c	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-13 14:51:09.690032+00	2026-10-13 14:51:09.690042+00
d83acbb4-07bb-4657-af79-378e05e7aa59	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	684b573e-627c-4a7f-9e71-6465004fa91d	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-13 14:51:09.892723+00	2026-10-13 14:51:09.892732+00
ce6787c8-7025-4957-9d48-32de255599ee	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4e2a14ab-cc7c-4812-a9e2-24601fde4a6b	null	{"name": "Couscous + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-13 14:51:09.97527+00	2026-10-13 14:51:09.975279+00
91238a8b-8d5e-4771-9f9a-ab97f7a33ddf	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	ea858ea2-6771-49c3-b09b-253f7cadb4e4	null	{"order_number": "2026-10-13-0005", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-13 14:51:34.400029+00	2026-10-13 14:51:34.400039+00
cce809b7-1492-4df5-99ba-4a8450925f70	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e962a6b9-8f15-4fcd-b60e-c70bf13ce481	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-13 14:51:34.497403+00	2026-10-13 14:51:34.497412+00
532c02b8-e357-4378-a85c-93ebdd3bf0fb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	97b3392b-011f-4fde-bd2e-95febe4f0171	null	{"name": "Passion", "quantity": 2, "line_total_xof": 2000}	\N	caisse-01	\N	2026-10-13 14:51:34.623984+00	2026-10-13 14:51:34.623993+00
8bdd8122-3507-467b-ab48-a419145d98cc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	5e365cb1-23a4-4474-9044-e18644140997	null	{"name": "Tchep + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-13 14:51:34.72277+00	2026-10-13 14:51:34.72278+00
0873c1aa-767c-4e0d-8665-41c73460a506	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	086666f7-a764-4812-b874-9826423dbb45	null	{"name": "Yassa + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-13 14:51:34.816668+00	2026-10-13 14:51:34.816679+00
14bd45fd-2937-415f-9431-d087e21e439e	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-13 14:52:27.211599+00	2026-10-13 14:52:27.211608+00
5676d4bc-df13-4282-a8a3-cfb26a3a08cc	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-13 14:53:49.872723+00	2026-10-13 14:53:49.872735+00
50243f24-b425-456f-877b-0345a5108e17	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	6f69dfb8-77f9-40ea-9405-ed3cfb579320	null	{"order_id": "ea858ea2-6771-49c3-b09b-253f7cadb4e4", "amount_xof": 9000, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-13 14:54:35.97349+00	2026-10-13 14:54:35.973496+00
68ae4342-256d-4c82-a973-89af821d3e4d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	2803b7c7-2a16-42f3-ac21-b139ef95dc02	null	{"order_id": "e39da534-1326-47b7-a6e2-b3bdccfbd904", "template": "B2B"}	\N	\N	\N	2026-10-13 14:56:01.388633+00	2026-10-13 14:56:01.388641+00
a824a96d-41a4-49ff-a4b5-1a43b1307bf6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	2803b7c7-2a16-42f3-ac21-b139ef95dc02	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000012", "attempts": 1}	\N	\N	\N	2026-10-13 14:56:02.142331+00	2026-10-13 14:56:02.142337+00
d231b073-0080-49fe-878e-48e59081923c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	88bb26c8-211a-450a-b8c3-372434e60909	null	{"order_id": "e39da534-1326-47b7-a6e2-b3bdccfbd904", "amount_xof": 6000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-13 14:56:02.193077+00	2026-10-13 14:56:02.193084+00
43387ceb-8a9c-48e1-ba11-781d90668185	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-13 15:00:57.726113+00	2026-10-13 15:00:57.726123+00
51738d93-e626-4229-a8a9-851e7a171fb7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 09:41:19.73496+00	2026-10-14 09:41:19.735045+00
52c42082-4d33-4343-be95-ef8cfa3e7c14	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	534d40ba-7ee4-47ac-93a0-080192232503	null	{"z_number": 3, "counted_cash_xof": 70000, "expected_cash_xof": 70000, "variance_xof": 0}	\N	caisse-01	\N	2026-10-14 09:41:57.79332+00	2026-10-14 09:41:57.793329+00
5b340f5c-e234-48bb-a094-790d76612504	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-14 10:38:13.706904+00	2026-10-14 10:38:13.707025+00
c9bd7e87-9971-431d-9cfb-7b0101412f3d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 11:02:05.615786+00	2026-10-14 11:02:05.616013+00
008b4d33-f71c-467e-af15-083b37d4bca9	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-14 11:02:15.000424+00	2026-10-14 11:02:15.000434+00
8ddb8311-b929-4b8b-a89e-cd6382857607	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 11:19:42.280032+00	2026-10-14 11:19:42.280042+00
1f56bae3-f384-46a7-a481-24bb48154aa7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	null	{"opening_float_xof": 50000, "business_date": "2026-10-14"}	\N	caisse-01	\N	2026-10-14 11:19:46.867254+00	2026-10-14 11:19:46.867266+00
fd1eb973-b645-4ad4-95b6-646ce4cdf531	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-14 11:21:32.953974+00	2026-10-14 11:21:32.953983+00
c56f60fc-42cf-4523-a7bd-946ecd6131a7	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-14 11:59:11.414802+00	2026-10-14 11:59:11.414883+00
7f981429-a079-4cd3-8072-74afec00d61a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 12:02:05.000522+00	2026-10-14 12:02:05.00053+00
6bcdef57-450d-4ab1-a94c-3da7cdeee269	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 12:14:22.386004+00	2026-10-14 12:14:22.386011+00
54a42f14-a500-460b-ae9e-f50ee88f3c04	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-14 12:30:22.860064+00	2026-10-14 12:30:22.860215+00
937d6afd-94d9-4dd1-b965-834f8bd0601a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 12:30:27.225476+00	2026-10-14 12:30:27.225483+00
19b688f0-a288-4522-a743-c1789063445e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 15:17:50.431162+00	2026-10-14 15:17:50.431171+00
fe20c88c-ae62-4a35-98cf-c17bf7d59576	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-14 15:18:04.013279+00	2026-10-14 15:18:04.013287+00
e76b4342-d9ee-43ed-87ee-2b5bdd16abc4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 15:18:39.718917+00	2026-10-14 15:18:39.718931+00
3a3dd7d3-3813-4ae6-9806-f2bc1c2ca0e9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	1d99a39f-4263-4b0f-b6dd-6544080aab4a	null	{"order_number": "2026-10-14-0001", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "guests_count": 4}	\N	caisse-01	\N	2026-10-14 15:18:58.024894+00	2026-10-14 15:18:58.024902+00
3046d4ce-b1e2-4964-94ad-8149ad345fd7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	38b38222-0e87-4f60-861a-3a20ef3dc6f8	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-14 15:18:58.171645+00	2026-10-14 15:18:58.171657+00
2a612a78-09a0-489f-87d6-8689ba1771a8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	babb9e2b-81fe-446e-9b48-c2fe6fc972f4	null	{"name": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-14 15:18:58.281445+00	2026-10-14 15:18:58.281457+00
fcf8340d-4bda-4dc1-98df-5c7cdcd0c0b7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	dab2f615-2a70-4af4-9c2e-5f815e2540e7	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-14 15:18:58.437262+00	2026-10-14 15:18:58.437271+00
8fc78038-8651-49a1-b96e-cf33d6637b50	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	748d475c-8653-4877-837a-ee4c9fe31737	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-14 15:18:58.562387+00	2026-10-14 15:18:58.562398+00
793a16ef-bab3-4f0a-9d7f-ac7ca2163957	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4b324c72-17f3-4951-b7f7-f917c7b1530d	null	{"name": "Passion", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-14 15:18:58.699475+00	2026-10-14 15:18:58.699486+00
a578ca5b-b186-4a4d-b4ef-22d7789db965	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 15:20:02.290991+00	2026-10-14 15:20:02.291+00
3145d43a-db17-46de-a75a-23cefae9caa3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	998f84b2-586b-47c9-98ce-bcd1becca088	null	{"order_number": "2026-10-14-0002", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-14 15:20:43.261049+00	2026-10-14 15:20:43.26106+00
9abab1ac-3fa8-4f38-a961-af91e984ec2b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e0cc0c69-f1c3-4507-8c36-48b5a865dd3c	null	{"name": "Igname bouillie + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-14 15:20:43.362551+00	2026-10-14 15:20:43.362564+00
89792abe-3d22-4915-baf1-30486c76ffe3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3076529a-b556-457b-94de-0135c6483259	null	{"name": "Tchep + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-14 15:20:43.542722+00	2026-10-14 15:20:43.542732+00
d4b3c9db-4311-4779-92bf-593259f23d86	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d247412b-4251-43ed-aa65-3915ea1c1b0d	null	{"name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-14 15:20:43.651148+00	2026-10-14 15:20:43.651158+00
6394bcdf-d78b-4d25-8000-5ecf713a8608	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	7f042d15-8463-4e26-9c0e-0ab5a61084c5	null	{"order_id": "998f84b2-586b-47c9-98ce-bcd1becca088", "template": "B2B"}	\N	\N	\N	2026-10-14 15:23:47.096905+00	2026-10-14 15:23:47.096918+00
74d2b581-2572-4973-aacc-3218f97947ef	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	7f042d15-8463-4e26-9c0e-0ab5a61084c5	null	{"status": "SUBMITTING", "is_uncertain": true, "external_number": null, "attempts": 1}	\N	\N	\N	2026-10-14 15:23:51.165286+00	2026-10-14 15:23:51.165293+00
d3db683b-5e42-4b42-a1b7-289a2aad9424	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	cd22b82a-d706-43b3-81ef-8483095f121c	null	{"order_id": "998f84b2-586b-47c9-98ce-bcd1becca088", "amount_xof": 13000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-14 15:23:51.283019+00	2026-10-14 15:23:51.283028+00
9449b96f-f4a0-4675-b424-3e6568285e3d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 15:24:48.290982+00	2026-10-14 15:24:48.290993+00
f4e7add5-d623-4b8e-a808-509a2b06fef4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:26:04.336265+00	2026-10-15 11:26:04.336274+00
3959d7be-16ec-4322-bda5-e51137016998	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8	null	{"order_number": "2026-10-14-0003", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-14 15:25:09.903406+00	2026-10-14 15:25:09.903414+00
7407a740-6718-4db8-a1f5-db86fcdb2334	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-14 15:37:07.264791+00	2026-10-14 15:37:07.264808+00
55beda87-11b1-4f04-81ac-e743d509a294	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9512a9e8-d86c-41e0-a5eb-6b23696a04e3	null	{"name": "Kabato Kope + Tripe", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-14 15:25:10.010472+00	2026-10-14 15:25:10.010485+00
d4eea514-0a68-4bbe-9808-ae1b41e11021	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 15:27:17.278734+00	2026-10-14 15:27:17.278742+00
36455e4a-f21e-4d8a-862a-be99fb496b5b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 15:32:06.62531+00	2026-10-14 15:32:06.625324+00
c15d1b85-3dc5-46d0-ace7-24d2277007f5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	ce2dd852-2947-4e23-b62e-4d8df1a69490	null	{"order_number": "2026-10-14-0004", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-14 15:32:31.416747+00	2026-10-14 15:32:31.416761+00
63f14fac-8110-488f-963a-7c98256bec16	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	5678587a-33a1-4145-b03c-900dc0e8b22f	null	{"order_id": "ce2dd852-2947-4e23-b62e-4d8df1a69490", "amount_xof": 3500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-14 15:35:30.362217+00	2026-10-14 15:35:30.362226+00
6ecb1742-6f51-4133-99c8-91f9962dc3ec	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a506b07b-13af-47d9-a403-62b6dcb2f442	null	{"name": "Kabato Kope + Tripe", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-14 15:32:31.537531+00	2026-10-14 15:32:31.537539+00
d5777b2e-724a-440e-9f4b-517621b15ba9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	98fd355a-9b64-4549-93c9-ae172607ec05	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-14 15:32:31.711629+00	2026-10-14 15:32:31.711639+00
f18e4eca-a730-43c5-af23-275fbda216e6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	92d76b7b-e01a-4b24-896c-b5f595d7ec6d	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-14 15:32:31.828435+00	2026-10-14 15:32:31.828447+00
82e5adf7-7c41-4a5f-a0cb-9d478d9343a2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-14 16:55:18.635641+00	2026-10-14 16:55:18.635648+00
1e0db764-ff62-4b3f-9578-0eae118bbc79	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	2d3f2a08-a6fd-4a0e-8890-e7e93a0fe81a	null	{"order_id": "4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8", "amount_xof": 2500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-14 16:55:33.588559+00	2026-10-14 16:55:33.588568+00
9f1fd3b4-03b0-4a71-94c7-120a942b1b71	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	879d36bd-6fa6-4206-8275-b6f83caf77ac	null	{"order_id": "1d99a39f-4263-4b0f-b6dd-6544080aab4a", "template": "B2B"}	\N	\N	\N	2026-10-14 16:56:02.150447+00	2026-10-14 16:56:02.150457+00
92e3f2db-8ca0-43da-a9f7-c2ec9401040c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	879d36bd-6fa6-4206-8275-b6f83caf77ac	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000014", "attempts": 1}	\N	\N	\N	2026-10-14 16:56:02.837398+00	2026-10-14 16:56:02.837406+00
2bb84883-302d-467d-85cc-745e47aad3a6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	0c5afc42-12f1-43c5-85cd-eb07feb63e08	null	{"order_id": "1d99a39f-4263-4b0f-b6dd-6544080aab4a", "amount_xof": 9500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-14 16:56:02.87553+00	2026-10-14 16:56:02.875537+00
0abf7d0c-d495-4714-ac2a-2181ee5ccefc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	null	{"z_number": 4, "counted_cash_xof": 78500, "expected_cash_xof": 78500, "variance_xof": 0}	\N	caisse-01	\N	2026-10-14 16:56:48.027553+00	2026-10-14 16:56:48.027567+00
912ea886-11a4-487c-9790-539bb9b38fb7	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-14 16:56:58.102925+00	2026-10-14 16:56:58.102931+00
a02b5b2a-4bd8-4104-a3fb-cd27d7765657	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 08:32:00.077577+00	2026-10-15 08:32:00.077592+00
e6d8c5d4-e633-4e87-af66-6428a44e93c9	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-15 08:32:13.040436+00	2026-10-15 08:32:13.040446+00
9e44ab82-0781-4f95-9cd5-43d353c2c856	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 09:46:11.539307+00	2026-10-15 09:46:11.539316+00
8b4772c4-9d7b-4fe9-9dc2-f3418b087f7e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	0e8d76cb-c7be-43a9-9975-18ecfb230858	null	{"opening_float_xof": 50000, "business_date": "2026-10-15"}	\N	caisse-01	\N	2026-10-15 10:08:39.93005+00	2026-10-15 10:08:39.930059+00
7810537d-603c-4e5b-a227-c445a2149adf	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-15 10:12:16.043205+00	2026-10-15 10:12:16.043214+00
ffe0506f-4c1c-465f-abd2-fb8f0edae9d4	4b5224bf-057a-4654-b13e-0e65ff403161	\N	fne.resolve	fne_document	7f042d15-8463-4e26-9c0e-0ab5a61084c5	{"status": "SUBMITTING", "last_error": "FneUncertainError: issue inconnue : ReadTimeout('timed out')"}	{"is_certified": true, "external_number": "1304777N26000000013"}	\N	\N	\N	2026-10-15 10:16:18.560321+00	2026-10-15 10:16:18.560386+00
03b4d90d-9ada-45a6-b19d-bdbc49e02d52	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 10:27:07.381495+00	2026-10-15 10:27:07.381505+00
11024b61-b45b-4b8b-8e77-4b1a4d112c11	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 10:30:01.344868+00	2026-10-15 10:30:01.34488+00
ff487614-ec29-4139-8a5c-5baf589e73d8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 11:08:28.197099+00	2026-10-15 11:08:28.197107+00
31d6869a-c2c5-4063-8b30-4ed016206e89	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	null	{"order_number": "2026-10-15-0001", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-15 11:08:43.756142+00	2026-10-15 11:08:43.756152+00
accf30df-f947-45c6-b675-a158a8697f6c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	00495238-f69c-4571-81bc-d9d72ad09b3c	null	{"name": "Kabato Lafri + Tripe", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-15 11:08:44.031151+00	2026-10-15 11:08:44.031161+00
d6a3bc95-741a-4683-b8ed-eb697520abed	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9c53774b-dcaa-4e6f-bd52-6cff9becbe2c	null	{"name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-15 11:08:44.168596+00	2026-10-15 11:08:44.168614+00
a9d89ab8-dcba-465d-88db-d2a8b9094985	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	64b22562-194e-477b-95e9-c05b70d1d6eb	null	{"name": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-15 11:08:44.291046+00	2026-10-15 11:08:44.291055+00
931df334-effe-4bdd-8da1-4a697e5a7aa9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	27d0b2c7-c0c3-49d3-a442-5b602f1e56a8	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-15 11:08:44.423755+00	2026-10-15 11:08:44.423764+00
e925ec33-e249-40b1-881a-c5b0d185f9b1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	52f27e70-12e6-4be9-bbae-5703a7e5cb02	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-15 11:08:44.547398+00	2026-10-15 11:08:44.547406+00
305ce856-f382-4e96-a396-286d6434197b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4a4b514e-91aa-4c97-b5cf-4e81bb072344	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-15 11:09:47.446713+00	2026-10-15 11:09:47.446723+00
9b15f7a9-8b25-4516-9d16-ee45edc379c3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	bc81b25c-e2a3-4bdb-982c-8e6565f78c57	null	{"name": "Atti\\u00e9k\\u00e9 + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-15 11:09:47.61459+00	2026-10-15 11:09:47.614604+00
871e6451-468c-479a-b8ad-7740bef3291f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	eec53167-02fb-4d83-99c3-fccd4fcfd5ac	null	{"name": "Passion", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-15 11:09:47.861041+00	2026-10-15 11:09:47.861054+00
fbad049f-445c-4a39-a157-e1ccb4067cfa	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 11:17:16.026196+00	2026-10-15 11:17:16.026206+00
d3b1a962-04d6-4b71-9192-2213b1ef1669	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-15 11:19:04.866472+00	2026-10-15 11:19:04.866482+00
b327038a-b427-47d3-b226-414ab70385ee	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	ORDER_CREATED	ORDER	ee578b03-ff99-40a0-9313-02085d248038	null	{"order_number": "2026-10-15-0002", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 1}	\N	test-dev	\N	2026-10-15 11:24:37.750729+00	2026-10-15 11:24:37.750737+00
efc02687-7240-46d2-ac20-92dcf8c5ebf1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:25:47.721402+00	2026-10-15 11:25:47.721602+00
c0cf3a3a-0ffc-4e85-9277-56c3211f7670	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:25:55.981788+00	2026-10-15 11:25:55.981797+00
d717f30f-3600-454b-8c6c-955dc8308092	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:26:10.283955+00	2026-10-15 11:26:10.283965+00
513c0976-e84f-44a2-a786-3c60dd2a377b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:26:17.488334+00	2026-10-15 11:26:17.488342+00
1ea4bc54-30c1-46d2-ba56-f71f337f12cc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:26:23.929529+00	2026-10-15 11:26:23.929537+00
a3ffc7df-6081-4653-af35-27409aa5b72b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:26:42.526727+00	2026-10-15 11:26:42.526734+00
519563a3-68a9-45b0-80e6-2e0cb4bbf5fd	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	9afbd9f2-da0c-4f3e-b309-fd0681fab463	null	{"order_number": "2026-10-15-0003", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 1}	\N	CAISSE-01	\N	2026-10-15 11:26:42.59+00	2026-10-15 11:26:42.590011+00
ec66028e-86bc-4014-9963-42370996e3bf	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:26:52.703302+00	2026-10-15 11:26:52.703308+00
b7f24e3b-38db-4de3-aa21-0316e995d545	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CANCELLED	ORDER	9afbd9f2-da0c-4f3e-b309-fd0681fab463	null	null	Test nettoyage	CAISSE-01	\N	2026-10-15 11:26:52.722109+00	2026-10-15 11:26:52.722121+00
b1ac12db-d624-4754-9688-56c9b15f7b3c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	CAISSE-01	127.0.0.1	2026-10-15 11:26:58.627822+00	2026-10-15 11:26:58.62783+00
d042a7b5-8d30-4038-af17-752736cbc3aa	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 11:27:39.294798+00	2026-10-15 11:27:39.294807+00
96645790-e476-4918-a5ac-e663c083fd71	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e1b02577-917d-4dbd-af18-11331af961e5	null	{"name": "Kabato Dah + Tripe", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-15 11:28:00.232928+00	2026-10-15 11:28:00.232938+00
c7328384-1a19-477b-a012-953ed5b97a92	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	7ac9c439-0089-49c2-9b6c-94596e07bf3b	null	{"name": "Kabato Lafri + Boeuf", "quantity": 2, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-15 11:28:00.3589+00	2026-10-15 11:28:00.358911+00
f181f5f6-848d-4c4b-a74f-e5506f3cec64	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3871eedc-4799-4a67-a609-01da2ea02095	null	{"name": "Tchep + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-15 11:28:00.472994+00	2026-10-15 11:28:00.473006+00
c3892a8a-50f2-4d32-baa7-0a0f326e0859	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	163291f6-3ec6-4aed-9ec2-cde110f320db	null	{"name": "D\\u00e9gu\\u00e9", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-15 11:28:00.596546+00	2026-10-15 11:28:00.596555+00
2562dd9a-2df6-4b62-bf7d-44e2df6eda44	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 11:31:07.292954+00	2026-10-15 11:31:07.292964+00
2cd78b81-9dbf-4ccf-bbb9-df99ce3ce600	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 11:49:34.524414+00	2026-10-15 11:49:34.524517+00
37f28c58-dfc9-454a-ad0e-9cdc39853918	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	d487a3b5-bf6b-440d-96bb-ffaa31fc9b68	null	{"order_id": "f2fb511b-1bdd-4b34-8174-1b6c7ab582b0", "amount_xof": 18500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-15 11:51:48.077939+00	2026-10-15 11:51:48.077946+00
91691dc9-c805-4c65-a338-4bcf115bd83b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	53738b3c-1ef5-4f0c-a620-f00af82e1bfe	null	{"order_id": "ee578b03-ff99-40a0-9313-02085d248038", "amount_xof": 11500, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-15 11:52:47.173736+00	2026-10-15 11:52:47.17374+00
435727eb-bdd3-409e-a0d7-60d820f39238	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	68380b5e-667a-4c22-b3b3-a4b9e0674607	null	{"order_number": "2026-10-15-0004", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "guests_count": 4}	\N	caisse-01	\N	2026-10-15 11:56:39.953256+00	2026-10-15 11:56:39.953264+00
ad5cf62d-6ffc-4e31-8e13-5966f2fcf749	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	f587ca4d-de87-494b-8884-c88a0cc4ae25	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-15 11:56:40.111326+00	2026-10-15 11:56:40.111334+00
513f02f4-a41d-492e-b064-57c18d765637	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1b8fe535-e9c6-4815-9008-3d8c85bd9cd8	null	{"name": "Couscous + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-15 11:56:40.289259+00	2026-10-15 11:56:40.289473+00
30a264bc-60bd-4b57-8974-5cb60cda60e2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	04f24f74-7622-466b-b090-0f065946e004	null	{"order_number": "2026-10-15-0005", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-15 12:00:03.958545+00	2026-10-15 12:00:03.958556+00
5aff68e1-52e2-4ecf-bf02-3be5f288922b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4a24926d-6840-4fa7-84eb-3b09d72a047b	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-15 12:00:04.076283+00	2026-10-15 12:00:04.076293+00
ceecce37-44b0-4f89-84a3-e7f5049af851	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a067553d-9435-4c8c-b85d-f7c0b88575cb	null	{"name": "Atti\\u00e9k\\u00e9 + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-15 12:00:04.31034+00	2026-10-15 12:00:04.310348+00
20186296-96ef-45e5-b9f7-252e8e7571c1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1f7f14ae-c6b5-4b00-8ac0-5fb69cbea6d3	null	{"name": "Atti\\u00e9k\\u00e9 + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-15 12:00:04.480371+00	2026-10-15 12:00:04.480381+00
51ed4558-d222-4b0f-bad8-f581526b66c6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	752f3cbe-7650-47f1-955a-9dc16fa28560	null	{"name": "Salade de fruits", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-15 12:00:04.608744+00	2026-10-15 12:00:04.608754+00
2e9db538-dbb0-4893-addb-60e806b5127c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	213b0d6a-2d11-449c-abbb-1cc1ed7caf31	null	{"name": "Tamarin", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-15 12:00:04.779366+00	2026-10-15 12:00:04.779375+00
d5a74ff7-cf26-4244-acd2-4ba4d2ffe2c3	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-15 12:10:08.227336+00	2026-10-15 12:10:08.227343+00
8062f2da-aa8c-40cf-b10a-95f56ff33b01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 12:10:11.270545+00	2026-10-15 12:10:11.270554+00
bfd01856-5de5-4f04-a04e-e5d478f9a8cb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 12:13:49.235898+00	2026-10-15 12:13:49.235911+00
36d73480-0d02-458c-a740-18d53117cbac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	f1917d71-6db8-46ac-bb8b-5e7b32711e5d	null	{"order_id": "04f24f74-7622-466b-b090-0f065946e004", "amount_xof": 13500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-15 12:14:45.773739+00	2026-10-15 12:14:45.773745+00
97688a47-ac96-46a2-bb6f-d9167e946593	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 12:18:08.239649+00	2026-10-15 12:18:08.239666+00
b8df483e-8c78-46af-bfc9-bd7b73eddaff	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 15:10:51.173843+00	2026-10-15 15:10:51.17387+00
66bdf90b-4f2e-44da-9e94-88989d7883e2	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-15 15:11:27.606521+00	2026-10-15 15:11:27.606536+00
8cc65bcd-c193-452c-a18c-3987cb2d5074	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	bbe0106e-b4e8-4e46-8f4c-561066cecb13	null	{"order_id": "68380b5e-667a-4c22-b3b3-a4b9e0674607", "amount_xof": 3000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-15 15:12:03.841681+00	2026-10-15 15:12:03.841686+00
81b12df9-1832-4493-a1fa-d7fd2c0eab6f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	null	{"order_number": "2026-10-15-0006", "table_id": "259ae2af-e711-442b-a6c7-1de4b25711ba", "guests_count": 4}	\N	caisse-01	\N	2026-10-15 15:14:23.942117+00	2026-10-15 15:14:23.94213+00
d8c9f60c-c759-4f04-8d71-57537ad4e84c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	76710ee7-e134-499a-a62d-4f66817077d0	null	{"name": "Kabato Lafri + Tripe", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-15 15:14:24.05678+00	2026-10-15 15:14:24.05679+00
e10d2917-5603-4f40-8806-a7e1f910814f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6372bf4e-3c1b-43f8-adb3-1426565a542a	null	{"name": "Atti\\u00e9k\\u00e9 + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-15 15:14:24.32634+00	2026-10-15 15:14:24.326347+00
e0b85461-d688-4e1f-9e1b-22abe135079a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b65f7fc1-54ee-4a17-9b55-39f24ddddb03	null	{"name": "Atti\\u00e9k\\u00e9 + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-15 15:14:24.540497+00	2026-10-15 15:14:24.540505+00
67df1d82-be90-4f3b-b6b4-cbfc183fe9f1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6620dead-1d26-4cc4-8f08-1c3936cb6947	null	{"name": "Alloco + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-15 15:14:25.031178+00	2026-10-15 15:14:25.031187+00
163e76c4-4e74-4d7c-99e5-9d9ce433568c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	cad7e9d9-a760-401a-84c0-2e62e32ac343	null	{"name": "Bissap", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-15 15:14:25.228811+00	2026-10-15 15:14:25.228822+00
15ea918d-5cb7-49fa-bf2b-b3e755133769	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	f13c512f-75da-4072-8178-30fe34d48f14	null	{"name": "Passion", "quantity": 2, "line_total_xof": 2000}	\N	caisse-01	\N	2026-10-15 15:14:25.479014+00	2026-10-15 15:14:25.479021+00
b7f231f9-058f-429b-8083-530983133ee6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 15:27:38.325556+00	2026-10-15 15:27:38.325569+00
02d2d62b-dfe4-40bc-ba81-eb313370e5ba	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 15:42:37.105741+00	2026-10-15 15:42:37.105831+00
60d54c59-91e6-4b69-9aa5-1231f39289d3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 15:45:33.932157+00	2026-10-15 15:45:33.93217+00
fae8e5f3-b16b-4b73-a6fe-1cd5a426246f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-15 16:40:59.469785+00	2026-10-15 16:40:59.469882+00
41989143-866b-45a5-b7eb-73475bbef5df	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	666975d6-7915-4b61-a067-680e8cfbb971	null	{"order_id": "778a91c8-9cce-44e7-91b9-e5ff90fd0a23", "amount_xof": 16000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-15 16:41:09.164044+00	2026-10-15 16:41:09.164051+00
d33b9c26-414e-4acc-9274-5830615be4ee	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-15 17:02:17.439816+00	2026-10-15 17:02:17.439908+00
53958f2f-e24d-4299-98a1-0defb5143261	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-16 09:49:05.929888+00	2026-10-16 09:49:05.929978+00
f195aa7a-5114-4879-a5b2-c66a49957bfd	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-16 09:49:17.021454+00	2026-10-16 09:49:17.021464+00
62563029-6b43-4e32-b2d9-ebbf2a924e15	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	722b3daf-c534-4a28-96a1-c7f866dcb6e4	null	{"order_number": "2026-10-15-0007", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-16 09:51:38.054224+00	2026-10-16 09:51:38.054232+00
ebc6785b-274c-4ad8-a64d-5f0bb737740d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	83dca401-8acc-4269-9260-ad3a9c28a80f	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-16 09:51:38.175681+00	2026-10-16 09:51:38.175691+00
7ca4182d-8666-4935-9dfc-41b56e8cbb53	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	04dde75d-0a3f-49ba-9381-1794cc5942af	null	{"name": "Tchep + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-16 09:51:38.308418+00	2026-10-16 09:51:38.308428+00
6c72d869-3790-4620-8e78-580668200aa5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	213f00dd-8b39-4ce9-b94f-7abcdcb0e2a4	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-16 09:51:38.428391+00	2026-10-16 09:51:38.428399+00
19d5f406-4516-4051-a13e-a79f8948538b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	3e7be164-b550-4bf0-acb8-086d7e054200	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-16 09:51:38.7721+00	2026-10-16 09:51:38.772109+00
8bcd4900-ebf0-4408-8ced-2d6974a54150	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	9a9daf47-c991-4852-b474-f2d9c12f44ec	null	{"order_number": "2026-10-15-0008", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 1}	\N	caisse-01	\N	2026-10-16 09:52:11.071181+00	2026-10-16 09:52:11.071194+00
7b7d98e3-eafd-4925-8ff6-d668c836fa16	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	cce56a6a-7d85-4538-bbb9-ff25c3a579f2	null	{"name": "Couscous + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-16 09:52:22.457986+00	2026-10-16 09:52:22.457996+00
e36333ce-99e6-4d23-8fea-c7adc9b1353c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	33a25eb6-f42f-43d3-b1b8-c3da96afdb1a	null	{"name": "Couscous + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-16 09:52:22.549982+00	2026-10-16 09:52:22.549991+00
d8759410-5c25-483b-b808-96f862813dd5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	18219b2f-b701-4d12-95c7-74e14fd684fb	null	{"order_id": "9a9daf47-c991-4852-b474-f2d9c12f44ec", "template": "B2B"}	\N	\N	\N	2026-10-16 09:55:45.904477+00	2026-10-16 09:55:45.904488+00
40f4075f-6247-4d67-93c5-ae54716df83b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	18219b2f-b701-4d12-95c7-74e14fd684fb	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000015", "attempts": 1}	\N	\N	\N	2026-10-16 09:55:46.479878+00	2026-10-16 09:55:46.479885+00
d15f216f-02fd-4e23-a15b-bfed3257dcab	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	22202f24-9b04-4266-a096-020dc012083b	null	{"order_id": "9a9daf47-c991-4852-b474-f2d9c12f44ec", "amount_xof": 5500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-16 09:55:46.741429+00	2026-10-16 09:55:46.74144+00
0d30ef26-d176-4db7-b83f-456298989b6e	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-16 09:55:59.000071+00	2026-10-16 09:55:59.00008+00
a8da991c-4a7d-416d-8816-80730ec2b02a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	336935f0-b189-4e84-b83a-c426bff0c33e	null	{"order_id": "722b3daf-c534-4a28-96a1-c7f866dcb6e4", "template": "B2B"}	\N	\N	\N	2026-10-16 10:02:00.38355+00	2026-10-16 10:02:00.383564+00
1271fa5d-9511-42f4-bd92-1b561b8f3d65	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	beb9d3e0-ea5c-4e65-8613-5e9362a53a79	null	{"name": "Frites + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-16 10:05:44.395136+00	2026-10-16 10:05:44.395145+00
45ad7f56-989d-459f-8580-175eb6e8e5f1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	336935f0-b189-4e84-b83a-c426bff0c33e	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000016", "attempts": 1}	\N	\N	\N	2026-10-16 10:02:00.982752+00	2026-10-16 10:02:00.98276+00
ab60933e-8f75-4cc7-a7bc-18979ed57a06	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1a7c9cbc-4934-40b4-9397-4292d94f7814	null	{"name": "Igname frite + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-16 10:07:43.59944+00	2026-10-16 10:07:43.599451+00
1b681ed5-15a5-4cc9-a143-6a287260a1c4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	4f79df43-0c12-4d28-8497-1bb9122f5b5d	null	{"order_id": "722b3daf-c534-4a28-96a1-c7f866dcb6e4", "amount_xof": 7500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-16 10:02:01.047864+00	2026-10-16 10:02:01.047873+00
b1eb47fa-c820-439c-9b72-14275b64a86d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	3caa47f0-5560-456a-830e-e0e31694dc3d	null	{"order_number": "2026-10-15-0009", "table_id": "6cf24b95-3c1e-473d-bdd8-2f22c321b558", "guests_count": 4}	\N	caisse-01	\N	2026-10-16 10:05:44.034297+00	2026-10-16 10:05:44.034307+00
befd2d22-1ffa-4e4e-a200-457bac72d610	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	37a7886d-6dc0-4da6-92bc-427b84bdf664	null	{"name": "Kabato Kope + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-16 10:11:24.663513+00	2026-10-16 10:11:24.663522+00
7a6aa685-ae02-4cbb-83d8-c8e56fa29a9b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	708257ab-a1d7-4b81-9095-02939ddb79a4	null	{"name": "Kabato Lafri + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-16 10:05:44.124253+00	2026-10-16 10:05:44.124261+00
4a812708-f3f1-4124-8fb9-068ed9680f4d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	669e0175-dc0d-4603-b26d-1dc2cc3936cc	null	{"name": "Kabato Lafri + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-16 10:11:24.745686+00	2026-10-16 10:11:24.745695+00
33c33227-e2d1-4ea4-a7b0-511ced991407	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d837faaa-c425-497e-83bc-3195091bccd8	null	{"name": "Alloco + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-16 10:05:44.493166+00	2026-10-16 10:05:44.493175+00
5a096bfe-75d1-48dc-ab39-49b827d24062	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	e8a42cf0-5a2f-41e7-85db-4a8ba423084d	null	{"order_number": "2026-10-15-0010", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-16 10:11:24.573316+00	2026-10-16 10:11:24.573327+00
d94af810-fac4-4e51-b8b1-7fa978eff1ad	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-16 10:25:33.421826+00	2026-10-16 10:25:33.421835+00
3779fd88-6b59-4dec-b935-4ae54abcf98c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	f1b90d2b-4330-4c41-9344-44c98e756582	null	{"order_id": "e8a42cf0-5a2f-41e7-85db-4a8ba423084d", "amount_xof": 5500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-16 10:25:56.853826+00	2026-10-16 10:25:56.853834+00
1521de8e-99b2-42e2-b860-200d05a7465b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	b33e307a-1901-436c-8e95-b2a2f02f2dc7	null	{"order_id": "3caa47f0-5560-456a-830e-e0e31694dc3d", "amount_xof": 12500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-16 10:26:17.6676+00	2026-10-16 10:26:17.667605+00
1b6ddefc-1ec7-4cc6-ab52-98bc1eb8b827	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-16 14:48:40.78518+00	2026-10-16 14:48:40.78561+00
11e0d3c3-6f06-4e8f-bfc9-339dd8035e0d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	0e8d76cb-c7be-43a9-9975-18ecfb230858	null	{"z_number": 5, "counted_cash_xof": 132000, "expected_cash_xof": 132000, "variance_xof": 0}	\N	caisse-01	\N	2026-10-16 14:49:24.33521+00	2026-10-16 14:49:24.335217+00
ffb5dd40-14a9-4800-be10-f11b9d90befa	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-16 14:49:41.118758+00	2026-10-16 14:49:41.118764+00
5f530390-637c-4534-be6e-04794924bf0b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-19 08:28:29.543366+00	2026-10-19 08:28:29.543475+00
052993e7-22ea-41c4-86f9-f6ccca47f14f	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-19 08:31:33.321678+00	2026-10-19 08:31:33.321689+00
03aa49b3-8129-43f1-8c31-6d8cd3940525	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-19 14:07:23.376922+00	2026-10-19 14:07:23.377018+00
ce50adad-b4c6-4644-9a15-ee9a5be26a7d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-19 14:10:45.279543+00	2026-10-19 14:10:45.279551+00
07729ccc-e9fc-4429-acda-abe7e2e4918a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	null	{"opening_float_xof": 0, "business_date": "2026-10-19"}	\N	caisse-01	\N	2026-10-19 14:11:08.285242+00	2026-10-19 14:11:08.285251+00
d44d00cd-e4bd-4dd0-a6f8-2d799eacf025	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	pos-terminal-1	127.0.0.1	2026-10-19 14:11:36.160683+00	2026-10-19 14:11:36.160691+00
f339bc6e-059a-40f0-bbe9-3694d7b9875d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-19 14:14:10.222965+00	2026-10-19 14:14:10.222971+00
8f717873-9125-4927-aca5-6699e7fa27a7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	CASH_MOVEMENT_IN	CASH_MOVEMENT	e1b4eeba-4424-4282-b536-4d977cd07d1c	null	{"type": "IN", "amount_xof": 25000, "reason": "Apport de monnaie"}	\N	caisse-01	\N	2026-10-19 14:15:11.748888+00	2026-10-19 14:15:11.748896+00
89b28b4d-a8fe-4f1f-a683-dc2d455f45f5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	41ec42f2-0c63-4e29-9fa8-c6b043ea9669	null	{"order_number": "2026-10-19-0001", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:16:21.892337+00	2026-10-19 14:16:21.892345+00
ad146ee0-8475-4df4-8bd5-8c18547e3c0c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ec7cb34b-f9f8-4048-8ab6-3965a0dc2777	null	{"name": "Tamarin", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-19 14:16:22.031352+00	2026-10-19 14:16:22.031367+00
a01f2b96-9993-4b73-8c9f-c49b185d3cd3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	8c408797-09fa-40ef-9fbf-ad48437aa1e5	null	{"name": "Atti\\u00e9k\\u00e9 + Sosso", "quantity": 2, "line_total_xof": 8000}	\N	caisse-01	\N	2026-10-19 14:16:22.248597+00	2026-10-19 14:16:22.248629+00
f45a412f-5f8a-48c6-a148-6cd6278f9d60	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9d1635ad-9141-43be-b522-24b25de88e11	null	{"name": "Atti\\u00e9k\\u00e9 + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:16:22.341009+00	2026-10-19 14:16:22.341017+00
64473fc4-3864-46c5-88f2-2993e51e8bef	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	43fa1db8-2abb-4f74-a08c-0cf4fe36602d	null	{"name": "Frites + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-19 14:16:22.432013+00	2026-10-19 14:16:22.432039+00
e764e716-4ade-4a48-b4dc-7b1822e3210a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	3f8f8dc6-11b6-4706-9a16-5033b227f0d1	null	{"order_number": "2026-10-19-0002", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-19 14:16:46.184103+00	2026-10-19 14:16:46.184112+00
e2da253d-8bd5-407d-add7-ee2d9cf48aa6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	5a3e9843-b8ca-40f9-bea9-f27448d3514c	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-19 14:16:46.274112+00	2026-10-19 14:16:46.274121+00
24ae5656-388c-4dd7-990f-60678ddb3554	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	83bbb028-9262-4677-9439-8039157c6f9d	null	{"name": "Tchep + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:16:46.379464+00	2026-10-19 14:16:46.379473+00
e6d672bb-6435-4ad9-add2-64d648c6300b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c579f85d-e2fd-49e4-add0-1bc48725f5a5	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:16:46.481765+00	2026-10-19 14:16:46.481774+00
8ecd0fd4-92f4-42a4-9602-8f4fe3f8b597	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	8c9eed27-2030-4ec1-aa14-99ba911bebc6	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:16:46.603463+00	2026-10-19 14:16:46.603471+00
8c55a8e2-8e87-46fc-97ba-c1234fe34d13	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-19 14:20:30.689763+00	2026-10-19 14:20:30.68977+00
1d2cbcc7-65be-40ca-afea-15d4ebcf6213	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	219650f5-63b9-4867-9c38-0f27414fcdc6	null	{"order_id": "3f8f8dc6-11b6-4706-9a16-5033b227f0d1", "amount_xof": 7500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:20:52.812763+00	2026-10-19 14:20:52.812772+00
2b2e71eb-3cbb-4965-9268-4eaee6f8d8e5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	89fe7d08-379c-4a4c-8d64-e4bfd7c5bb0d	null	{"order_id": "41ec42f2-0c63-4e29-9fa8-c6b043ea9669", "amount_xof": 15000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:22:39.639128+00	2026-10-19 14:22:39.639136+00
d805c266-7764-498c-849e-f6951a9304f8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-19 14:27:28.060918+00	2026-10-19 14:27:28.060929+00
b890cdfe-c77e-4bb3-885f-abd8ac2a1dfd	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-19 14:33:20.415565+00	2026-10-19 14:33:20.415573+00
a3d6adec-4966-4b07-913b-aac41669a632	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	234ba969-bf26-4b05-88fa-6f0de2f6664d	null	{"order_number": "2026-10-19-0003", "table_id": "05aa9ad5-594d-4926-8d1a-508eec179caf", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:33:45.52557+00	2026-10-19 14:33:45.52558+00
0c07e927-9174-47b2-86a7-dc43e06bca24	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0a4a791d-0c43-41af-8209-77b08537a300	null	{"name": "Kabato Dah + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:33:45.645932+00	2026-10-19 14:33:45.645941+00
2e677585-9464-45e2-8903-861b048570b1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6b8624be-7805-4420-9343-6e904c4f7bef	null	{"name": "Tchep + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:33:45.77873+00	2026-10-19 14:33:45.778738+00
1233e77d-5813-475f-8d52-bc075ceea142	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	866a64d1-2be2-4b21-b65c-1e2df646e66c	null	{"name": "Couscous + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:33:45.857426+00	2026-10-19 14:33:45.857432+00
a38d7d24-ffb4-44c2-aa62-8a6223762c90	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	04fd647a-c8df-49f9-867d-9a8ca272fed6	null	{"name": "Sauce Feuille + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:33:45.925512+00	2026-10-19 14:33:45.925519+00
27da5cf2-61e5-4c43-9d24-bf4f211ba9ab	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	82620f6e-2b11-4bc8-b541-aac6644dc809	null	{"order_number": "2026-10-19-0004", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:34:17.766337+00	2026-10-19 14:34:17.766347+00
ab73a9d9-3918-48a2-a88f-dc5d1c4fd8d2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	82f96417-6c7b-4327-aa1c-5fadac1e96ea	null	{"name": "Kabato Dah + Tripe", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:34:17.862448+00	2026-10-19 14:34:17.862457+00
d66bc141-da46-4e26-8db7-626c4607e150	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4e2b68e4-94ba-4107-aeb4-9f451a8ac388	null	{"name": "Kabato Dah + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:34:17.978835+00	2026-10-19 14:34:17.978842+00
819afc30-934d-46ce-a7f1-e53b4ed405a4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	80b83243-1c32-4411-ac5f-42f1bc4c8c15	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:34:18.39986+00	2026-10-19 14:34:18.399867+00
0ee0fd45-64ba-4c35-8a0b-aa0d47adb4a9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b26cddaa-96b3-4974-87e4-cc6c8f0fdb5d	null	{"name": "Kabato Kope + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:34:29.650885+00	2026-10-19 14:34:29.650893+00
1ade41f2-883a-4ec7-992f-d15c049738b4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	22a3651f-0572-4e95-9495-950f6e805b10	null	{"name": "Kabato Dah + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:34:29.736953+00	2026-10-19 14:34:29.736965+00
134b4374-0523-4e70-ae65-29a2467cf4e4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	2df6412e-4597-48c0-92b7-7ee0800a879f	null	{"name": "Kabato Kope + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:34:29.892341+00	2026-10-19 14:34:29.892349+00
74ec2936-9499-403b-84fd-37e051f4db7a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	33665a80-45bb-45e9-8223-8a0a71dc7ad6	null	{"name": "Sauce L\\u00e9gume + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:34:41.466572+00	2026-10-19 14:34:41.466581+00
8498a5be-01e9-459b-9268-491328651caa	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	a898bc47-55b9-4ec3-a2e7-19e82a3d0552	null	{"order_number": "2026-10-19-0007", "table_id": "830e098a-77ec-4022-8736-ed94c5fe3cfe", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:34:56.587079+00	2026-10-19 14:34:56.587086+00
2d3b6ff8-7e00-4f5d-b101-dc4a73e56b24	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c	null	{"order_number": "2026-10-19-0008", "table_id": "259ae2af-e711-442b-a6c7-1de4b25711ba", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:35:13.34467+00	2026-10-19 14:35:13.344681+00
367be5f7-5ebc-4865-a0e0-a01b01dae20c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	a92d24c7-d36a-42c6-85e4-2b2d009b45e8	null	{"name": "Couscous + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:35:13.450049+00	2026-10-19 14:35:13.45006+00
1185d3b4-84df-4072-9ecb-9c4a4d90afea	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	ce4b412b-bb66-4375-b20e-22162f259ba7	null	{"name": "Couscous + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-19 14:35:13.618943+00	2026-10-19 14:35:13.618952+00
6407510a-ed78-4dbb-bfb6-3eb60957c0d9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	de4360df-4871-4dd9-b2d8-cb3a55dd40ab	null	{"name": "Bissap", "quantity": 3, "line_total_xof": 1500}	\N	caisse-01	\N	2026-10-19 14:35:13.748615+00	2026-10-19 14:35:13.748624+00
eb1fd946-d9b3-4b3b-a2e3-c7609ebdf3df	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	e7997130-0ca2-4611-9a0f-547906350cfc	null	{"order_number": "2026-10-19-0009", "table_id": "083e37af-15ee-44be-9b2e-21eef62593fc", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:35:38.274818+00	2026-10-19 14:35:38.274824+00
9a51a0ad-cbde-4ce6-b399-bdfc84954cd4	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	16f74585-dba3-45e7-9e07-447b4a0fda11	null	{"name": "Kabato Lafri + Tripe", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:35:38.349619+00	2026-10-19 14:35:38.349625+00
b7e30757-6e7c-4d76-bf64-4c12c841bf3c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	2f76b8fc-a269-4c37-ab2f-1241d47303dd	null	{"name": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-19 14:35:38.461673+00	2026-10-19 14:35:38.461684+00
ea610878-13c1-42cf-a569-4c8fc0e0f8cb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	aa42d526-b039-486f-8474-f821cd4cb4f8	null	{"name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-19 14:35:38.569536+00	2026-10-19 14:35:38.569543+00
90cb39c8-0f91-466b-8a52-102de0ea64c3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	6417888b-7b85-4cba-a757-f11e671b4b48	null	{"name": "Igname bouillie + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-19 14:35:38.638714+00	2026-10-19 14:35:38.638721+00
efe304ce-4f73-4b7e-a2d8-c17f23288758	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	8e089f05-4650-4ecf-bb28-bf72020f998b	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:35:38.811732+00	2026-10-19 14:35:38.81174+00
8e691f39-57f0-4393-a232-a45ae2649cd9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	365427b5-2558-4c3a-979e-ceb00811a8b9	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:35:50.450017+00	2026-10-19 14:35:50.450042+00
ad1004e5-374c-43a0-b329-083ed1988245	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	36cb1c85-b2bb-4c4a-878a-e22057ece53e	null	{"name": "Bissap", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:35:50.577416+00	2026-10-19 14:35:50.577426+00
82f03b77-0b54-4527-9787-f1f546005c7b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	58757248-c95c-4fee-b357-23616f2ae02a	null	{"name": "D\\u00e9gu\\u00e9", "quantity": 1, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-19 14:35:50.69658+00	2026-10-19 14:35:50.696586+00
548be398-7613-4932-8af9-6010fa1fa572	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-21 10:36:09.238535+00	2026-10-21 10:36:09.238644+00
cf3ad27c-5d45-42cb-82d2-682bcaeb5dce	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9282d5d5-8d19-46ec-aaaa-1f212800c9a3	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:33:45.991286+00	2026-10-19 14:33:45.991293+00
d381d970-2192-470f-bfd6-cc95997f8781	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	58349962-6094-4bbd-b533-10913532d3f3	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-19 14:34:18.263128+00	2026-10-19 14:34:18.263135+00
3dcb8d1e-f60d-4644-a0ce-2f396d60951b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	f9d1e3e6-2304-4c7f-a39b-f9b161967b17	null	{"name": "Tamarin", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:34:18.328104+00	2026-10-19 14:34:18.328111+00
0fbbd8de-0b04-46d6-9018-2012018c3c68	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	9187a7af-42c4-4b1e-98df-51cf420ae7c0	null	{"order_number": "2026-10-19-0005", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:34:29.570668+00	2026-10-19 14:34:29.570677+00
7bc499ef-c4f4-4c6d-b18c-a9167f95d341	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e87244f4-9d66-400c-b4e4-d4a43714643d	null	{"name": "Salade de fruits", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-19 14:34:30.011667+00	2026-10-19 14:34:30.011673+00
31521f23-7dce-4958-b446-d7c8fca7410c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	f1c7d23d-fe31-429b-8723-b5582ccba29c	null	{"order_number": "2026-10-19-0006", "table_id": "47e6e141-b494-4813-8c9c-3c455c91a422", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:34:41.079237+00	2026-10-19 14:34:41.079243+00
4ff2b005-6561-4de3-ab8f-020ba1122ede	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	bc209e5d-104e-4948-9d51-6234faa8c9f2	null	{"name": "Sauce L\\u00e9gume + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:34:41.160659+00	2026-10-19 14:34:41.160668+00
eea77183-1928-42c6-8126-4f75d5354527	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	46123169-1866-41ff-8814-ec61f4c335d2	null	{"name": "Sauce Dah + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-19 14:34:41.305065+00	2026-10-19 14:34:41.305076+00
890475d4-be0e-4d40-885b-c1a26f2b0cf8	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c77a9599-7a3d-47f6-a041-6dec7c0fc134	null	{"name": "Sauce Feuille + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:34:41.398925+00	2026-10-19 14:34:41.398933+00
26b2d4fc-75c3-481f-a47e-ea0700400c7f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	1cae931d-443b-4fe6-8912-9b6b6b2b2448	null	{"name": "Igname bouillie + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-19 14:34:56.677687+00	2026-10-19 14:34:56.677698+00
5529b102-4c15-440c-8590-9e4e9f5b8190	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	51503f33-18b5-4c32-b1bc-d3b199f20aaf	null	{"name": "Atti\\u00e9k\\u00e9 + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-19 14:34:56.794097+00	2026-10-19 14:34:56.794104+00
433f9743-e96a-4cff-8c6b-f193fcaf587e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	de0ced94-da04-4435-8d64-c152c6c51501	null	{"name": "Igname bouillie + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-19 14:34:56.918275+00	2026-10-19 14:34:56.918282+00
d93fcc7d-04b8-495e-872f-9708a30b4b08	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	d6ab7a35-644f-43bc-8dbf-22e54c560183	null	{"name": "Tamarin", "quantity": 4, "line_total_xof": 2000}	\N	caisse-01	\N	2026-10-19 14:34:56.996742+00	2026-10-19 14:34:56.996749+00
d1472dc1-c96c-4737-b4d2-9cece39493fe	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	fe6387e1-2fbe-4c67-8b09-3abed1548a19	null	{"name": "Igname frite + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-19 14:35:38.723625+00	2026-10-19 14:35:38.723636+00
3f8c834a-e7a1-439d-8198-95cb6ecb7197	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	dec8e488-1dc9-48fc-a597-47ca3a193e10	null	{"order_number": "2026-10-19-0010", "table_id": "6cf24b95-3c1e-473d-bdd8-2f22c321b558", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:35:50.363597+00	2026-10-19 14:35:50.363603+00
4aca1936-20c4-4746-8569-26e674447699	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	6138d6a8-6f96-47ed-b093-baf0cfb04fa8	null	{"order_number": "2026-10-19-0011", "table_id": "f3904853-0688-4341-9830-a0a9716161bc", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:36:03.775717+00	2026-10-19 14:36:03.775725+00
820601fd-b602-44ea-bfe8-e95c8d815dea	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	null	{"order_number": "2026-10-19-0012", "table_id": "d3602f9e-0bc4-4386-8e39-367925cb190a", "guests_count": 4}	\N	caisse-01	\N	2026-10-19 14:36:19.038192+00	2026-10-19 14:36:19.038202+00
415fcc05-5e91-40a3-b7c0-4a609581f9ec	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e88b711f-304b-45c0-9100-09b826c1f6a6	null	{"name": "Kabato Kope + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:36:19.193453+00	2026-10-19 14:36:19.193462+00
3b2aa58d-f4ec-475d-953b-d639a49e1249	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	0d908938-0dfa-460c-9d76-4a581df9a2f8	null	{"name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "quantity": 1, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-19 14:36:19.602602+00	2026-10-19 14:36:19.602612+00
9aa16eb6-a119-41f7-ba5c-38ea55358473	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	9f2d63c8-0494-421c-aabc-6b8a07746d65	null	{"name": "Alloco + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:36:03.90087+00	2026-10-19 14:36:03.90088+00
e1c2837b-1fa0-440d-95f3-9eac73a0f19a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	53ad068b-a728-4abb-82cc-10d4a86684f5	null	{"name": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-19 14:36:19.516619+00	2026-10-19 14:36:19.516625+00
469f5092-5e54-422b-9597-c770c11a91ae	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	67947b4f-72d5-4161-b9df-12d42bb30188	null	{"name": "Petit pois + Sosso", "quantity": 1, "line_total_xof": 4500}	\N	caisse-01	\N	2026-10-19 14:36:04.058247+00	2026-10-19 14:36:04.058255+00
ce6aa366-1f6c-4517-aea3-990a78f5f392	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	f9ee0394-5536-4a4e-9cfc-5796ae15686b	null	{"name": "Tchep + Poulet", "quantity": 2, "line_total_xof": 5000}	\N	caisse-01	\N	2026-10-19 14:36:04.16996+00	2026-10-19 14:36:04.169971+00
436f3949-f4c4-422d-9b81-29ff6d90abb2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	4c044de5-4661-41df-bd90-eaa0077eac9a	null	{"name": "Kabato Dah + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:36:19.111212+00	2026-10-19 14:36:19.111218+00
3ec0473c-ade7-47e2-93e6-9d60a54ac399	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	70cbf674-334f-438f-8a06-6e7fbb45a3c1	null	{"name": "Couscous + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:36:19.302748+00	2026-10-19 14:36:19.302757+00
6dc2eef8-e568-4af6-8a3a-9ca9838bc76b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	8ab33d9a-642e-4fbb-8003-9aab6ff68a26	null	{"name": "Couscous + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:36:19.434289+00	2026-10-19 14:36:19.434298+00
6d0598a9-9539-4181-9631-4f6a37b70e45	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	8c1faad9-c719-4e21-bd8b-e3db15751754	null	{"order_number": "2026-10-19-0013", "table_id": null, "guests_count": 1}	\N	caisse-01	\N	2026-10-19 14:37:04.417963+00	2026-10-19 14:37:04.417972+00
fac1edf5-a29e-4c1f-b5a9-3b268a88f4d5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	480ca1f0-9063-4c5b-850c-fcfb00852c18	null	{"name": "Tchep + Poisson", "quantity": 1, "line_total_xof": 3000}	\N	caisse-01	\N	2026-10-19 14:37:04.52273+00	2026-10-19 14:37:04.522739+00
3186bbe0-8bfb-436a-af8a-dd3b45d76eb0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	062efe63-f363-4243-947e-c04475759760	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-19 14:37:04.604436+00	2026-10-19 14:37:04.604443+00
e717b799-0de4-4dbb-bd5e-3361dbc6875e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	86a5ee86-001a-44f7-8a63-6f8d0d855fcd	null	{"name": "Yassa + Boeuf", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-19 14:37:04.710388+00	2026-10-19 14:37:04.710394+00
104fec85-5141-4708-b719-2f3d1a4315ef	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	996bb8ed-319b-4908-b66f-3b1ee2aa83bf	null	{"name": "Bissap", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-19 14:37:04.788858+00	2026-10-19 14:37:04.788864+00
1e01f1a3-e090-409b-bd92-19919d1c5835	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	a5dcb845-5276-44ac-926e-eee1be0cf785	null	{"order_id": "a898bc47-55b9-4ec3-a2e7-19e82a3d0552", "template": "B2B"}	\N	\N	\N	2026-10-19 14:39:11.103417+00	2026-10-19 14:39:11.103427+00
2fedfcb9-77b7-4877-9ff2-b5a17dbd277d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	a5dcb845-5276-44ac-926e-eee1be0cf785	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000017", "attempts": 1}	\N	\N	\N	2026-10-19 14:39:11.879145+00	2026-10-19 14:39:11.879151+00
aec90331-78fb-45ae-b290-1de756015af3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	a6071376-6f80-47c5-b70e-1674bc6706e5	null	{"order_id": "a898bc47-55b9-4ec3-a2e7-19e82a3d0552", "amount_xof": 13500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-19 14:39:12.21529+00	2026-10-19 14:39:12.215297+00
4a5797c9-787e-4a4c-a59f-b6e7342f5fea	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	bbf6f146-2e7d-4c1a-92ae-f4c28b58e32b	null	{"order_id": "e7997130-0ca2-4611-9a0f-547906350cfc", "template": "B2B"}	\N	\N	\N	2026-10-19 14:41:29.648144+00	2026-10-19 14:41:29.648152+00
a37f081a-efc7-41a9-bd66-8ffc023c167b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	bbf6f146-2e7d-4c1a-92ae-f4c28b58e32b	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000018", "attempts": 1}	\N	\N	\N	2026-10-19 14:41:30.314262+00	2026-10-19 14:41:30.314266+00
7979bf55-90b5-4121-bc12-6d0b4f1a19ff	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	2114e5e1-2451-41df-9bc1-b25f7382c564	null	{"order_id": "e7997130-0ca2-4611-9a0f-547906350cfc", "amount_xof": 20500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-19 14:41:30.392788+00	2026-10-19 14:41:30.392794+00
8cc5e619-8a90-4f2c-b266-15a40f19e577	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	369550f7-dbb0-496d-b9ba-0e8b2c37b701	null	{"order_id": "8c1faad9-c719-4e21-bd8b-e3db15751754", "amount_xof": 10000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:42:39.22965+00	2026-10-19 14:42:39.229653+00
f74f64f7-a5d1-4d02-b2f4-018717c71f80	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	4630958e-a91c-426c-8d21-13cc50daf48c	null	{"order_number": "2026-10-19-0014", "table_id": "259ae2af-e711-442b-a6c7-1de4b25711ba", "guests_count": 1}	\N	caisse-01	\N	2026-10-19 14:43:09.641891+00	2026-10-19 14:43:09.641898+00
42aeda17-8f8f-4530-9286-dbcd9862a0c7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	b7125df5-8a1c-4068-be73-252499a54347	null	{"name": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-19 14:43:23.96232+00	2026-10-19 14:43:23.962326+00
e22dd4aa-120c-4b70-a119-075229874857	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	8636e7b1-3422-4fb7-a9cf-56669892503b	null	{"name": "Bissap", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-19 14:43:24.063063+00	2026-10-19 14:43:24.063071+00
f358bfb1-22a2-4e6f-a775-96db5af3b19b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	3bec01b1-2954-4bb5-bb9c-9cf95068b21f	null	{"order_id": "dec8e488-1dc9-48fc-a597-47ca3a193e10", "amount_xof": 2000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:44:09.595986+00	2026-10-19 14:44:09.595993+00
19cde9f4-313a-4e68-87b2-3701c2274439	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	bd86f281-ceb4-46eb-a183-1f86bb0869ca	null	{"order_id": "82620f6e-2b11-4bc8-b541-aac6644dc809", "amount_xof": 10000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:44:26.419304+00	2026-10-19 14:44:26.419309+00
90ff3764-4c70-460e-af5a-e512eeefb7cf	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	395a14da-f7b8-44e4-98fd-9f527159c498	null	{"order_id": "234ba969-bf26-4b05-88fa-6f0de2f6664d", "amount_xof": 11000, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:45:04.450652+00	2026-10-19 14:45:04.450658+00
5cae1423-6ef2-486f-893c-cdb57bbabfc5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	564d9fcf-ffbd-4e2c-a492-e3b046174f99	null	{"order_id": "b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1", "amount_xof": 20000, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:45:32.376442+00	2026-10-19 14:45:32.376446+00
5f8da205-aa77-461e-8d53-50af0d881fc5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	582db3ba-ce42-4d99-b3a6-914709af83b3	null	{"order_id": "6138d6a8-6f96-47ed-b093-baf0cfb04fa8", "amount_xof": 12000, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:46:12.420052+00	2026-10-19 14:46:12.420057+00
89d7fb01-ac43-4c1e-a70f-574140b1d6e1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	6fad81ff-5ef5-4f76-8d93-b3baab109246	null	{"order_id": "9187a7af-42c4-4b1e-98df-51cf420ae7c0", "amount_xof": 9000, "method": "MOBILE_MONEY", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:47:33.545566+00	2026-10-19 14:47:33.545572+00
2203d4d8-3951-4e96-889f-8e8c0599a79e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	8e962b5a-1289-45e0-98f8-a11d6cdd718a	null	{"order_id": "f1c7d23d-fe31-429b-8723-b5582ccba29c", "amount_xof": 12000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:51:28.682948+00	2026-10-19 14:51:28.682951+00
7787b1cf-befc-4d12-a6ad-1daf881b314a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	8668c8b2-69a6-47ae-bece-9b80903790fa	null	{"order_id": "0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c", "template": "B2B"}	\N	\N	\N	2026-10-19 14:53:05.809788+00	2026-10-19 14:53:05.809801+00
4dbecd54-6c9a-44a8-a771-46fa16c507e6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	8668c8b2-69a6-47ae-bece-9b80903790fa	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000019", "attempts": 1}	\N	\N	\N	2026-10-19 14:53:06.420481+00	2026-10-19 14:53:06.420487+00
ed79172e-c393-4e2b-900a-f43ec21e8f2d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	0053d599-4c29-4019-b493-c6c794434838	null	{"order_id": "0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c", "amount_xof": 7500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-19 14:53:06.648663+00	2026-10-19 14:53:06.648667+00
549d20a9-db9b-411a-91d2-c54ab318985a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	41641af7-f183-4c6e-b3a6-343c29a16a90	null	{"order_id": "4630958e-a91c-426c-8d21-13cc50daf48c", "amount_xof": 5000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-19 14:53:52.314196+00	2026-10-19 14:53:52.314201+00
b1654ba6-a17f-435d-9cb6-3e6640b2e2ee	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-19 15:18:30.696895+00	2026-10-19 15:18:30.697042+00
bb82956a-a949-49fb-9a04-225551802578	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-19 15:30:08.425202+00	2026-10-19 15:30:08.425283+00
98f4573e-a485-41d6-8dd7-9a48ffba2939	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-19 15:49:58.359442+00	2026-10-19 15:49:58.359451+00
a206044d-7c2a-4ab7-b8d2-4b3290b36c65	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	null	{"z_number": 6, "counted_cash_xof": 128000, "expected_cash_xof": 128000, "variance_xof": 0}	\N	caisse-01	\N	2026-10-19 15:51:55.804397+00	2026-10-19 15:51:55.804403+00
2a3a8954-6ccc-4e09-a81d-8b30076a454c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-20 11:27:24.748801+00	2026-10-20 11:27:24.748988+00
7e61cdd5-896d-4e90-9e21-2d4df16f168a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	a47b2f40-5c96-4b9e-9269-d673c78b5a50	null	{"opening_float_xof": 50000, "business_date": "2026-10-20"}	\N	caisse-01	\N	2026-10-20 11:29:31.879871+00	2026-10-20 11:29:31.879884+00
44dbc578-cd30-418d-83ed-0130142ceaae	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	cfdf234b-e450-4b8d-a49a-863dc774908e	null	{"order_number": "2026-10-20-0001", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 4}	\N	caisse-01	\N	2026-10-20 11:31:28.42529+00	2026-10-20 11:31:28.425298+00
743cb372-0124-487f-8a1a-65b7f7a4c5c9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	aca05917-ddde-47f0-99ae-a66f3d4a5c00	null	{"name": "Kabato Dah + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-20 11:31:28.548064+00	2026-10-20 11:31:28.548078+00
499775c8-1aed-41ac-9258-62cdeffeb8fe	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	c17213e9-2f5a-4bed-accc-16c49fb91d85	null	{"name": "Tchep + Mouton", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-20 11:31:28.680164+00	2026-10-20 11:31:28.680173+00
ec1acae3-4086-4e55-9507-ea4d9959d300	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	355aa3fe-84db-4a21-8310-a24e00d52726	null	{"order_number": "2026-10-20-0002", "table_id": "17c3433b-b05c-4e93-9b13-56834f10ea3a", "guests_count": 1}	\N	caisse-01	\N	2026-10-20 11:31:45.44248+00	2026-10-20 11:31:45.442491+00
95fa1496-2a19-4c29-946b-01c178f993e5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	62ffcec9-2dee-454e-8632-b26a0f373f47	null	{"name": "Tchep + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-20 11:31:55.016506+00	2026-10-20 11:31:55.016517+00
7de97f4b-38a8-4ca1-9416-1db8abe9b59b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	2e80f04f-2f6f-4279-b053-48dcdf8b7e66	null	{"name": "Tamarin", "quantity": 2, "line_total_xof": 1000}	\N	caisse-01	\N	2026-10-20 11:31:55.112048+00	2026-10-20 11:31:55.112057+00
92106989-81a9-4f5a-a542-f2c46a87a641	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-20 11:32:25.00684+00	2026-10-20 11:32:25.00685+00
452ad9cb-bfeb-4a90-9882-84361df8634e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-20 11:33:03.676886+00	2026-10-20 11:33:03.676894+00
2d57e9f8-283e-4022-9049-e4be83fdb359	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.issue	fne_document	e59879dd-a76e-41ab-b208-313109c92899	null	{"order_id": "cfdf234b-e450-4b8d-a49a-863dc774908e", "template": "B2B"}	\N	\N	\N	2026-10-20 11:33:58.578272+00	2026-10-20 11:33:58.578283+00
fadd1526-70e6-4836-a986-ae545209ef9d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	fne.submit	fne_document	e59879dd-a76e-41ab-b208-313109c92899	null	{"status": "CERTIFIED", "is_uncertain": false, "external_number": "1304777N26000000020", "attempts": 1}	\N	\N	\N	2026-10-20 11:33:59.1548+00	2026-10-20 11:33:59.154809+00
2483d4f2-c8f9-4c72-ab07-da05184c8f4d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	4c232eb6-f36a-4931-ab15-ced6028bb8c9	null	{"order_id": "cfdf234b-e450-4b8d-a49a-863dc774908e", "amount_xof": 6000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": true}	\N	caisse-01	\N	2026-10-20 11:33:59.472347+00	2026-10-20 11:33:59.472355+00
d315aace-503b-4eae-8dd9-d5680030315b	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-20 11:34:15.179887+00	2026-10-20 11:34:15.179898+00
83c987a6-0611-4870-9efb-63c68797bc71	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-20 16:34:28.182468+00	2026-10-20 16:34:28.182474+00
538d8176-45c4-4127-a6d8-22977d55314c	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-20 16:34:41.7845+00	2026-10-20 16:34:41.784508+00
fb3fa0f2-074e-431f-a94b-e2941c5e2f08	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-20 16:37:03.704327+00	2026-10-20 16:37:03.704338+00
55ec172e-2f67-4c85-a77d-7e0c65de0117	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-20 16:40:24.728336+00	2026-10-20 16:40:24.728345+00
6d6b4872-1573-4b98-83d2-ff671c39820d	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	c35cbde7-7bb8-4aac-985b-92ff31fff7e8	null	{"order_id": "355aa3fe-84db-4a21-8310-a24e00d52726", "amount_xof": 3500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-20 16:41:50.332403+00	2026-10-20 16:41:50.33241+00
ea6ddd9a-cb52-41f7-ae03-7840e77c23bc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	a47b2f40-5c96-4b9e-9269-d673c78b5a50	null	{"z_number": 7, "counted_cash_xof": 59500, "expected_cash_xof": 59500, "variance_xof": 0}	\N	caisse-01	\N	2026-10-20 16:42:20.666486+00	2026-10-20 16:42:20.666495+00
db7dee89-698a-4c40-ab00-cdb61c909a9e	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-20 16:42:31.259122+00	2026-10-20 16:42:31.259137+00
bee044c7-1359-43bd-89da-1dd9cc3adaff	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-21 09:40:48.220734+00	2026-10-21 09:40:48.220746+00
6bdd0782-489d-4bae-94c7-37aa789ffb20	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	db678c86-c0e1-4913-90ee-7d0ca403978e	null	{"opening_float_xof": 50000, "business_date": "2026-10-21"}	\N	caisse-01	\N	2026-10-21 09:40:59.541503+00	2026-10-21 09:40:59.541515+00
1029d4ef-65e9-46d0-a499-d3de000a8837	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-21 09:47:14.461463+00	2026-10-21 09:47:14.461471+00
7d8cc256-0b04-4a8f-84af-cb7d8eeebeed	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-21 09:59:19.720259+00	2026-10-21 09:59:19.720394+00
5464871f-f0f5-4afa-bcb3-eb8359cb7a0e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-21 10:05:38.271947+00	2026-10-21 10:05:38.271956+00
7849b85c-b822-45a0-ba6e-c8a9d72f0bf6	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-21 10:16:38.526544+00	2026-10-21 10:16:38.526556+00
62de8680-6677-42a1-82a9-e1b8040f42a2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-21 11:21:44.157391+00	2026-10-21 11:21:44.157522+00
9f1243b2-6efc-47d1-a2a1-6841cb009ecc	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-21 11:33:50.853194+00	2026-10-21 11:33:50.853205+00
47589bd8-a9bc-4eda-8ac9-02cb3577c029	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-21 12:55:10.639209+00	2026-10-21 12:55:10.639215+00
105d5f94-5951-4406-87b3-79443a02c320	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-21 13:05:52.246186+00	2026-10-21 13:05:52.246194+00
8eff44f8-7afe-499a-99cd-a683b11d94bc	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-21 13:06:03.332973+00	2026-10-21 13:06:03.332982+00
e172ea84-77b8-48aa-a9f4-2a6a370e9257	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-21 14:40:24.589254+00	2026-10-21 14:40:24.589263+00
4feb0f68-bc4e-49a0-91da-8cfc867c9166	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-21 15:52:04.916991+00	2026-10-21 15:52:04.917002+00
31976825-c13d-46ee-a5f4-01e3700f5b75	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 10:23:29.765563+00	2026-10-22 10:23:29.765666+00
56d00745-59c5-4d84-8b60-d3d281c56839	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 10:25:04.449495+00	2026-10-22 10:25:04.449505+00
51ecc048-5a53-4352-96ec-b4ee68ea9302	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 10:27:47.568874+00	2026-10-22 10:27:47.568892+00
04dc6482-a4d5-4aa7-8c23-aa143f41c9a0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 10:27:56.271295+00	2026-10-22 10:27:56.271305+00
e988df54-453d-4123-a2be-e012f0ad9027	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 10:30:25.594425+00	2026-10-22 10:30:25.594437+00
02cde5f8-b287-4d4a-a552-15cd93bbca97	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 10:51:43.107577+00	2026-10-22 10:51:43.107587+00
71db0ad6-542d-43a4-9bca-84c9c76109ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	db678c86-c0e1-4913-90ee-7d0ca403978e	null	{"z_number": 8, "counted_cash_xof": 50000, "expected_cash_xof": 50000, "variance_xof": 0}	\N	caisse-01	\N	2026-10-22 10:52:04.432458+00	2026-10-22 10:52:04.432468+00
7e870a1f-15ee-4bbd-a441-eec72fdd0120	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:05:53.762945+00	2026-10-22 11:05:53.763077+00
53acb1f6-f84b-4e8c-b68f-0242c75a715c	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:06:03.874254+00	2026-10-22 11:06:03.874263+00
7e38ce6a-8b49-4056-ba07-cfc5063d137a	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:10:15.12722+00	2026-10-22 11:10:15.12723+00
23477ef1-5bea-4985-bd04-609a71e180e5	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:11:45.309549+00	2026-10-22 11:11:45.309559+00
164dc97f-cc4a-4012-a1cf-1dee03dfcc79	695652d7-7ab3-4b5d-a001-d4096cb849a0	\N	LOGIN_SUCCESS	USER	695652d7-7ab3-4b5d-a001-d4096cb849a0	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:15:43.995459+00	2026-10-22 11:15:43.995471+00
b7ca5a45-e5bc-453c-a83b-ce1b6edfb0e5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:15:50.172651+00	2026-10-22 11:15:50.172664+00
202a2d93-09fd-45b7-a8c8-090265bc58ef	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:15:56.560097+00	2026-10-22 11:15:56.560106+00
b293078d-31da-489c-8bb3-c3d5c14eff76	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:16:11.044046+00	2026-10-22 11:16:11.044054+00
b7520a0c-b030-486c-bda4-01ea0bda141a	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 11:24:10.990978+00	2026-10-22 11:24:10.990988+00
9d685f4c-285d-4773-aa03-f3ec4815fe34	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 13:52:47.764189+00	2026-10-22 13:52:47.764202+00
56649c1a-7f64-4ed2-9038-e4278a5c7b6b	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-22 13:55:12.795611+00	2026-10-22 13:55:12.795622+00
66fe840f-c2dd-4a0e-a227-2791c061a936	\N	\N	PRINT_TERMINAL_CREATED	PRINT_TERMINAL	b5e7a5f4-c84a-47e9-beed-cd584111ace2	null	{"name": "Poste-Comptoir-1"}	\N	\N	\N	2026-10-22 14:47:54.274296+00	2026-10-22 14:47:54.274304+00
4bac2ccb-0caa-4ba1-a161-ae9101faf07c	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 16:31:14.701594+00	2026-10-22 16:31:14.701603+00
fb62ab05-4b73-43d3-8396-2480c5a8ecae	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 16:31:28.445646+00	2026-10-22 16:31:28.44566+00
d20fc5cc-8728-487f-a925-8584d6437106	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-22 16:41:58.81931+00	2026-10-22 16:41:58.819327+00
16decb58-0f71-4e4c-84df-ea9b4a65b78c	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 16:43:46.97308+00	2026-10-22 16:43:46.9731+00
788bdbb7-3229-4423-b827-4fac9690b369	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 16:43:52.595009+00	2026-10-22 16:43:52.595024+00
e0325343-cd54-4ff4-ad0f-e0d3777bfde4	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 17:01:12.698151+00	2026-10-22 17:01:12.69816+00
e6853322-9275-4869-a233-79a847050ae9	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	test-device	127.0.0.1	2026-10-22 17:38:10.335528+00	2026-10-22 17:38:10.335538+00
601ffdf5-a74c-4010-8ffb-cfa82ad5acb3	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-22 17:56:55.11892+00	2026-10-22 17:56:55.118933+00
85df4838-e718-4c44-8eb0-6b37e38497e6	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 17:58:01.060814+00	2026-10-22 17:58:01.060824+00
9c5da650-fc30-449f-b8a0-106a65d2caeb	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-22 18:43:37.496803+00	2026-10-22 18:43:37.496814+00
94c80c9f-3f95-4836-9e65-cbbfde45eb47	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 18:51:35.100614+00	2026-10-22 18:51:35.100623+00
2a611eff-ac0c-4156-8921-765a0acf56ac	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-22 18:51:40.205378+00	2026-10-22 18:51:40.205386+00
68693f58-677c-46c4-ac91-03951dc450ec	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 19:00:19.531755+00	2026-10-22 19:00:19.531768+00
38bdd89e-b32c-4c2c-a0a0-78df12f7b4eb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 19:00:24.236243+00	2026-10-22 19:00:24.236254+00
09a6509b-6325-446e-ada2-618fe8c86b9a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	cd0d53b5-fb69-40f5-bbbc-653961ec963e	null	{"opening_float_xof": 100000, "business_date": "2026-10-22"}	\N	caisse-01	\N	2026-10-22 19:00:54.165848+00	2026-10-22 19:00:54.165861+00
9b5b698f-2c30-4605-a936-59afe3000035	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	c259aa5a-5c56-48e4-af2d-2cd301af43d8	null	{"order_number": "2026-10-22-0001", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "guests_count": 4}	\N	caisse-01	\N	2026-10-22 19:01:35.285639+00	2026-10-22 19:01:35.28565+00
98fe279f-849f-4d28-aa00-bc8c4707af18	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	560b9dd9-c883-4328-aeb8-26747f369ea8	null	{"name": "Salade Panach\\u00e9e + Poulet", "quantity": 1, "line_total_xof": 2500}	\N	caisse-01	\N	2026-10-22 19:01:35.453078+00	2026-10-22 19:01:35.453089+00
7bdd4a25-92a3-4a6a-8350-b7f6ba305d90	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	e5045925-ac9d-483b-b04c-b25422fd2a1d	null	{"name": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "line_total_xof": 4000}	\N	caisse-01	\N	2026-10-22 19:01:35.63295+00	2026-10-22 19:01:35.63296+00
d99aee9c-9103-470d-9e84-de41d6b61a16	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	088e8d7e-74e3-4e9a-8336-71bc26eb87d6	null	{"name": "Jus de citron", "quantity": 1, "line_total_xof": 500}	\N	caisse-01	\N	2026-10-22 19:01:35.729228+00	2026-10-22 19:01:35.729238+00
096fd202-e1ba-4996-b85a-87535d712969	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_CREATED	ORDER	9d70470c-a448-4666-8a3b-26a894e407ad	null	{"order_number": "2026-10-22-0002", "table_id": "cb2c0d43-facf-4ddc-bda4-b99afa2ec289", "guests_count": 1}	\N	caisse-01	\N	2026-10-22 19:02:09.400442+00	2026-10-22 19:02:09.400455+00
de9cd6b1-cae3-4bf5-9f7d-bcd8391be34b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 19:10:22.632193+00	2026-10-22 19:10:22.632201+00
b23ba371-c765-4cd0-8011-11b40bd4e4b7	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	ORDER_ITEM_ADDED	ORDER_ITEM	79bb649e-ad5c-4cfe-be65-85b53215f00e	null	{"name": "Foufou/foutou faux brochet", "quantity": 1, "line_total_xof": 3500}	\N	caisse-01	\N	2026-10-22 19:10:39.584566+00	2026-10-22 19:10:39.584575+00
faf94c75-b0e8-4ba0-80af-04f1513d56e5	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	0099ca67-a281-462c-8219-6f7866a594af	null	{"order_id": "9d70470c-a448-4666-8a3b-26a894e407ad", "amount_xof": 3500, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-22 19:10:58.671487+00	2026-10-22 19:10:58.671504+00
bc6e38a0-b696-4e2e-99fc-4d276fc3fb0a	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	PAYMENT_CAPTURED	PAYMENT	f242cc60-ae41-4eb8-bdc1-06a66f39c670	null	{"order_id": "c259aa5a-5c56-48e4-af2d-2cd301af43d8", "amount_xof": 7000, "method": "CASH", "order_status": "PAID", "due_xof": 0, "fne_requested": false}	\N	caisse-01	\N	2026-10-22 19:11:12.322297+00	2026-10-22 19:11:12.322315+00
b57f5da4-d1fc-43f5-a8e5-8deac4190a4b	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-22 19:34:24.797398+00	2026-10-22 19:34:24.797509+00
999f9bbb-a6fc-4557-9916-b54e54e911e9	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_CLOSED	CASH_SESSION	cd0d53b5-fb69-40f5-bbbc-653961ec963e	null	{"z_number": 9, "counted_cash_xof": 110500, "expected_cash_xof": 110500, "variance_xof": 0}	\N	caisse-01	\N	2026-10-22 19:35:13.798696+00	2026-10-22 19:35:13.798706+00
17293492-6475-4bf3-ab55-1c4fbd31c243	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 10:16:26.46941+00	2026-10-23 10:16:26.46942+00
e3416989-0082-4c99-88bc-9b8a98eb84f0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	SESSION_OPENED	CASH_SESSION	63d77089-d60c-446e-8363-bab14c8ca3d9	null	{"opening_float_xof": 100000, "business_date": "2026-10-23"}	\N	caisse-01	\N	2026-10-23 10:16:31.343034+00	2026-10-23 10:16:31.343042+00
f98dfde9-129a-4210-94eb-eb299ba16d1f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 10:16:46.534456+00	2026-10-23 10:16:46.534463+00
f36fe777-f3cc-4425-a986-a7f5cb5cbf19	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 10:19:40.335867+00	2026-10-23 10:19:40.335874+00
371e5917-d1d9-49f8-b481-58134d24f1df	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 10:29:14.561679+00	2026-10-23 10:29:14.561686+00
9d8b9b8a-428a-4274-ac6b-9d92eb370e98	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 10:30:14.411707+00	2026-10-23 10:30:14.411717+00
ee264b5f-fde0-412b-aa4d-2ae71b14e290	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-23 10:31:26.438821+00	2026-10-23 10:31:26.438834+00
55d5f183-f294-4d9f-a18b-7de59792aa7c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 10:44:52.014835+00	2026-10-23 10:44:52.014846+00
cfea5830-836f-4693-9c31-a0f80919a83f	\N	\N	LOGIN_FAILED	AUTH	\N	null	null	PIN erroné ou utilisateur verrouillé	caisse-01	127.0.0.1	2026-10-23 10:50:17.297594+00	2026-10-23 10:50:17.297604+00
f7521bee-fe26-4688-8627-9d921ad8ecb2	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 10:50:21.186855+00	2026-10-23 10:50:21.186867+00
b5374790-1507-4350-893d-2c67ebb47b4e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:04:22.623983+00	2026-10-23 11:04:22.623993+00
f7bfb673-07c4-48ea-a73f-76de918e1b6e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:16:25.596571+00	2026-10-23 11:16:25.596581+00
58b78088-becb-45d5-aa59-8fe446dcfab1	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:24:23.501428+00	2026-10-23 11:24:23.501438+00
1312fa7c-d4d8-49ad-a2c2-71070da36669	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:31:55.416352+00	2026-10-23 11:31:55.416362+00
71af9cef-d8d6-496d-ae99-b2d035cf2a30	4b5224bf-057a-4654-b13e-0e65ff403161	\N	LOGIN_SUCCESS	USER	4b5224bf-057a-4654-b13e-0e65ff403161	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:32:04.894029+00	2026-10-23 11:32:04.894039+00
0740ed3e-d55f-46a3-8d46-44f96f2da654	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:45:27.142765+00	2026-10-23 11:45:27.142776+00
b9b32b0d-7341-4214-aaac-42036162c783	4b5224bf-057a-4654-b13e-0e65ff403161	\N	CATEGORY_UPDATED	CATEGORY	725977b4-b95d-4b97-8979-c9b03b716e54	{"name": "Accompagnements", "kind": "FOOD", "sort_order": 0, "fiscal_group": "PLATS", "is_active": true}	{"name": "Suppl\\u00e9ments", "kind": "FOOD", "sort_order": 0, "fiscal_group": "PLATS", "is_active": true}	\N	caisse-01	\N	2026-10-23 11:54:26.692879+00	2026-10-23 11:54:26.693014+00
64a593a2-8640-4aaf-ae02-2c62bfca32d3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:54:43.881528+00	2026-10-23 11:54:43.881544+00
80e31d6e-3a80-42f0-a9e7-f7b73bd59dc3	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	LOGIN_SUCCESS	USER	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:54:49.658799+00	2026-10-23 11:54:49.658807+00
4d7095ca-db1a-42ef-8471-f3ab8634bff1	a3e01053-c2ad-4631-910a-0eb48345e5b1	\N	LOGIN_SUCCESS	USER	a3e01053-c2ad-4631-910a-0eb48345e5b1	null	null	\N	caisse-01	127.0.0.1	2026-10-23 11:57:21.970197+00	2026-10-23 11:57:21.970206+00
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
bcdcb45c-2c0c-4a3d-a652-bce53ec4a1bd	2026-10-22	\N	4b5224bf-057a-4654-b13e-0e65ff403161	MARCHE_APPOINT	284280	Marché d'approvisionnement	Achats viandes & poissons 2026-10-22	\N	2026-10-22 16:47:00.507692+00	2026-10-22 16:47:00.507706+00
\.


--
-- Data for Name: cash_movements; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.cash_movements (id, cash_session_id, user_id, type, amount_xof, reason, created_at, updated_at) FROM stdin;
e1b4eeba-4424-4282-b536-4d977cd07d1c	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	IN	25000	Apport de monnaie	2026-10-19 14:15:11.739157+00	2026-10-19 14:15:11.739169+00
\.


--
-- Data for Name: cash_registers; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.cash_registers (id, name, printer_config, is_active, created_at, updated_at) FROM stdin;
0192384a-3000-7000-8000-000000000001	Caisse Principale	\N	t	2026-10-03 16:12:32.729226+00	2026-10-03 16:12:32.729234+00
caisse-01	Caisse 01 (Bar / Principal)	\N	t	2026-10-03 16:54:16.623973+00	2026-10-03 16:54:16.623973+00
caisse-02	Caisse 02 (Terrasse / Mobile)	\N	t	2026-10-03 16:54:16.623973+00	2026-10-03 16:54:16.623973+00
\.


--
-- Data for Name: cash_sessions; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.cash_sessions (id, cash_register_id, opened_by_user_id, closed_by_user_id, business_date, status, opening_float_xof, opened_at, closed_at, z_number, expected_cash_xof, counted_cash_xof, variance_xof, closing_breakdown, totals_snapshot, notes, created_at, updated_at) FROM stdin;
61245d2f-8301-4acc-a965-12f74778b946	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06	CLOSED	50000	2026-10-06 11:07:33.739504+00	2026-10-06 15:40:31.982331+00	1	142000	142000	0	{"2000": 1, "10000": 14}	{"z_number": 1, "opening_float_xof": 50000, "total_sales_ttc_xof": 107500, "total_sales_ht_xof": 107500, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 92000, "MOBILE_MONEY": 15500}, "sales_by_category": {"Sp\\u00e9cial Kabato": 22000, "Sp\\u00e9cial Jus": 3500, "Sp\\u00e9cial S\\u00e9n\\u00e9gal": 18000, "Sp\\u00e9cial Salade": 11500, "Sp\\u00e9cial Sauce": 2500, "Sp\\u00e9cial Desserts": 1500, "Sp\\u00e9cial Ivoirienne": 42500, "Sp\\u00e9cial Oriental": 6000}, "sales_by_item": [{"product_name": "Frites + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 3, "unit_price_xof": 5000, "total_ttc_xof": 15000}, {"product_name": "Kabato Lafri + Boeuf", "category": "Sp\\u00e9cial Kabato", "quantity": 4, "unit_price_xof": 2500, "total_ttc_xof": 10000}, {"product_name": "Frites + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 4000, "total_ttc_xof": 8000}, {"product_name": "Tchep + Mouton", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 2, "unit_price_xof": 3500, "total_ttc_xof": 7000}, {"product_name": "Atti\\u00e9k\\u00e9 + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 3500, "total_ttc_xof": 7000}, {"product_name": "Yassa + Boeuf", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Salade Panach\\u00e9e + Sosso", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Alloco + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Kabato Dah + Mouton", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Couscous + Mouton", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Yassa + Mouton", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Igname frite + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Kabato Kope + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Kabato Lafri + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Kabato Lafri + Tripe", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Sauce Feuille + Poulet", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Alloco + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Frites + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Couscous + Boeuf", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Yassa + Poulet", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Salade Panach\\u00e9e + Boeuf", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Passion", "category": "Sp\\u00e9cial Jus", "quantity": 2, "unit_price_xof": 1000, "total_ttc_xof": 2000}, {"product_name": "D\\u00e9gu\\u00e9", "category": "Sp\\u00e9cial Desserts", "quantity": 1, "unit_price_xof": 1000, "total_ttc_xof": 1000}, {"product_name": "Tamarin", "category": "Sp\\u00e9cial Jus", "quantity": 2, "unit_price_xof": 500, "total_ttc_xof": 1000}, {"product_name": "Bissap", "category": "Sp\\u00e9cial Jus", "quantity": 1, "unit_price_xof": 500, "total_ttc_xof": 500}, {"product_name": "Salade de fruits", "category": "Sp\\u00e9cial Desserts", "quantity": 1, "unit_price_xof": 500, "total_ttc_xof": 500}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 142000, "counted_cash_xof": 142000, "variance_xof": 0, "closing_breakdown": {"2000": 1, "10000": 14}, "orders_count": 8, "cancelled_orders_count": 0}	\N	2026-10-06 11:07:33.749019+00	2026-10-06 15:40:31.988557+00
bec954fb-ce8e-4e82-b546-abecd853d1ac	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08	CLOSED	50000	2026-10-08 10:44:25.675226+00	2026-10-08 15:44:45.647249+00	2	104000	104000	0	{"2000": 2, "10000": 10}	{"z_number": 2, "opening_float_xof": 50000, "total_sales_ttc_xof": 77000, "total_sales_ht_xof": 77000, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 54000, "MOBILE_MONEY": 23000}, "sales_by_category": {"Sp\\u00e9cial Ivoirienne": 25000, "Sp\\u00e9cial Jus": 12000, "Sp\\u00e9cial Desserts": 8000, "Sp\\u00e9cial Kabato": 14500, "Sp\\u00e9cial Sauce": 5000, "Sp\\u00e9cial Oriental": 9000, "Sp\\u00e9cial S\\u00e9n\\u00e9gal": 3500}, "sales_by_item": [{"product_name": "Atti\\u00e9k\\u00e9 + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 3, "unit_price_xof": 2500, "total_ttc_xof": 7500}, {"product_name": "Frites + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Igname frite + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Sauce L\\u00e9gume + Poulet", "category": "Sp\\u00e9cial Sauce", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Igname bouillie + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Bissap", "category": "Sp\\u00e9cial Jus", "quantity": 9, "unit_price_xof": 500, "total_ttc_xof": 4500}, {"product_name": "Passion", "category": "Sp\\u00e9cial Jus", "quantity": 4, "unit_price_xof": 1000, "total_ttc_xof": 4000}, {"product_name": "Tamarin", "category": "Sp\\u00e9cial Jus", "quantity": 7, "unit_price_xof": 500, "total_ttc_xof": 3500}, {"product_name": "Tchep + Mouton", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Kabato Dah + Mouton", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Kabato Kope + Mouton", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Couscous + Mouton", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "D\\u00e9gu\\u00e9", "category": "Sp\\u00e9cial Desserts", "quantity": 3, "unit_price_xof": 1000, "total_ttc_xof": 3000}, {"product_name": "Lait", "category": "Sp\\u00e9cial Desserts", "quantity": 3, "unit_price_xof": 1000, "total_ttc_xof": 3000}, {"product_name": "Couscous + Poisson", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Alloco + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Kope + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Couscous + Poulet", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Dah + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Lafri + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Salade de fruits", "category": "Sp\\u00e9cial Desserts", "quantity": 4, "unit_price_xof": 500, "total_ttc_xof": 2000}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 104000, "counted_cash_xof": 104000, "variance_xof": 0, "closing_breakdown": {"2000": 2, "10000": 10}, "orders_count": 8, "cancelled_orders_count": 0}	\N	2026-10-08 10:44:25.695205+00	2026-10-08 15:44:45.701569+00
534d40ba-7ee4-47ac-93a0-080192232503	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13	CLOSED	50000	2026-10-13 11:06:39.018118+00	2026-10-14 09:41:57.791211+00	3	70000	70000	0	{"10000": 7}	{"z_number": 3, "opening_float_xof": 50000, "total_sales_ttc_xof": 46500, "total_sales_ht_xof": 46500, "total_sales_vat_xof": 0, "payments_by_method": {"MOBILE_MONEY": 26500, "CASH": 20000}, "sales_by_category": {"Sp\\u00e9cial Jus": 7000, "Sp\\u00e9cial Ivoirienne": 12500, "Sp\\u00e9cial Sauce": 9000, "Sp\\u00e9cial Salade": 6500, "Sp\\u00e9cial S\\u00e9n\\u00e9gal": 6500, "Sp\\u00e9cial Kabato": 2500, "Sp\\u00e9cial Oriental": 2500}, "sales_by_item": [{"product_name": "Alloco + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Salade Panach\\u00e9e + Sosso", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Sauce Feuille + Mouton", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Yassa + Mouton", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Passion", "category": "Sp\\u00e9cial Jus", "quantity": 3, "unit_price_xof": 1000, "total_ttc_xof": 3000}, {"product_name": "Sauce L\\u00e9gume + Poisson", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Tchep + Poisson", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Bissap", "category": "Sp\\u00e9cial Jus", "quantity": 5, "unit_price_xof": 500, "total_ttc_xof": 2500}, {"product_name": "Frites + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Atti\\u00e9k\\u00e9 + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Alloco + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Sauce Dah + Poulet", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Salade Panach\\u00e9e + Poulet", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Lafri + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Couscous + Poulet", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Tamarin", "category": "Sp\\u00e9cial Jus", "quantity": 3, "unit_price_xof": 500, "total_ttc_xof": 1500}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 70000, "counted_cash_xof": 70000, "variance_xof": 0, "closing_breakdown": {"10000": 7}, "orders_count": 5, "cancelled_orders_count": 0}	\N	2026-10-13 11:06:39.049195+00	2026-10-14 09:41:57.806404+00
8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14	CLOSED	50000	2026-10-14 11:19:46.842336+00	2026-10-14 16:56:48.026261+00	4	78500	78500	0	{"1000": 1, "2000": 1, "5000": 1, "10000": 7, "coin_500": 1}	{"z_number": 4, "opening_float_xof": 50000, "total_sales_ttc_xof": 28500, "total_sales_ht_xof": 28500, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 28500}, "sales_by_category": {"Sp\\u00e9cial S\\u00e9n\\u00e9gal": 6500, "Sp\\u00e9cial Salade": 9000, "Sp\\u00e9cial Desserts": 500, "Sp\\u00e9cial Jus": 2500, "Sp\\u00e9cial Ivoirienne": 5000, "Sp\\u00e9cial Kabato": 5000}, "sales_by_item": [{"product_name": "Igname bouillie + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Kabato Kope + Tripe", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Salade Panach\\u00e9e + Sosso", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Tchep + Mouton", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Tchep + Poisson", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Bissap", "category": "Sp\\u00e9cial Jus", "quantity": 2, "unit_price_xof": 500, "total_ttc_xof": 1000}, {"product_name": "Passion", "category": "Sp\\u00e9cial Jus", "quantity": 1, "unit_price_xof": 1000, "total_ttc_xof": 1000}, {"product_name": "Salade de fruits", "category": "Sp\\u00e9cial Desserts", "quantity": 1, "unit_price_xof": 500, "total_ttc_xof": 500}, {"product_name": "Tamarin", "category": "Sp\\u00e9cial Jus", "quantity": 1, "unit_price_xof": 500, "total_ttc_xof": 500}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 78500, "counted_cash_xof": 78500, "variance_xof": 0, "closing_breakdown": {"1000": 1, "2000": 1, "5000": 1, "10000": 7, "coin_500": 1}, "orders_count": 4, "cancelled_orders_count": 0}	\N	2026-10-14 11:19:46.860003+00	2026-10-14 16:56:48.033391+00
0e8d76cb-c7be-43a9-9975-18ecfb230858	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15	CLOSED	50000	2026-10-15 10:08:39.823139+00	2026-10-16 14:49:24.331976+00	5	132000	132000	0	{"2000": 1, "10000": 13}	{"z_number": 5, "opening_float_xof": 50000, "total_sales_ttc_xof": 93500, "total_sales_ht_xof": 93500, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 82000, "MOBILE_MONEY": 11500}, "sales_by_category": {"Sp\\u00e9cial Kabato": 21000, "Sp\\u00e9cial Ivoirienne": 36500, "Sp\\u00e9cial Jus": 7000, "Sp\\u00e9cial Salade": 9000, "Sp\\u00e9cial S\\u00e9n\\u00e9gal": 9500, "Sp\\u00e9cial Desserts": 2500, "Sp\\u00e9cial Oriental": 8000}, "sales_by_item": [{"product_name": "Atti\\u00e9k\\u00e9 + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 2, "unit_price_xof": 4000, "total_ttc_xof": 8000}, {"product_name": "Frites + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 3, "unit_price_xof": 2500, "total_ttc_xof": 7500}, {"product_name": "Tchep + Poisson", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Kabato Lafri + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Kabato Lafri + Tripe", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Kabato Lafri + Boeuf", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Couscous + Poulet", "category": "Sp\\u00e9cial Oriental", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Atti\\u00e9k\\u00e9 + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Alloco + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Salade Panach\\u00e9e + Sosso", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Tchep + Mouton", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Alloco + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Igname frite + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Passion", "category": "Sp\\u00e9cial Jus", "quantity": 3, "unit_price_xof": 1000, "total_ttc_xof": 3000}, {"product_name": "Couscous + Poisson", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Atti\\u00e9k\\u00e9 + Boeuf", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Atti\\u00e9k\\u00e9 + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Dah + Tripe", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Kope + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Bissap", "category": "Sp\\u00e9cial Jus", "quantity": 4, "unit_price_xof": 500, "total_ttc_xof": 2000}, {"product_name": "Tamarin", "category": "Sp\\u00e9cial Jus", "quantity": 4, "unit_price_xof": 500, "total_ttc_xof": 2000}, {"product_name": "Salade de fruits", "category": "Sp\\u00e9cial Desserts", "quantity": 3, "unit_price_xof": 500, "total_ttc_xof": 1500}, {"product_name": "D\\u00e9gu\\u00e9", "category": "Sp\\u00e9cial Desserts", "quantity": 1, "unit_price_xof": 1000, "total_ttc_xof": 1000}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 132000, "counted_cash_xof": 132000, "variance_xof": 0, "closing_breakdown": {"2000": 1, "10000": 13}, "orders_count": 9, "cancelled_orders_count": 1}	\N	2026-10-15 10:08:39.904277+00	2026-10-16 14:49:24.348847+00
0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19	CLOSED	0	2026-10-19 14:11:08.256498+00	2026-10-19 15:51:55.801971+00	6	128000	128000	0	{"1000": 1, "2000": 1, "5000": 5, "10000": 10}	{"z_number": 6, "opening_float_xof": 0, "total_sales_ttc_xof": 155000, "total_sales_ht_xof": 155000, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 103000, "MOBILE_MONEY": 52000}, "sales_by_category": {"Sp\\u00e9cial Oriental": 14000, "Sp\\u00e9cial Salade": 22000, "Sp\\u00e9cial Kabato": 24500, "Sp\\u00e9cial S\\u00e9n\\u00e9gal": 27000, "Sp\\u00e9cial Sauce": 14500, "Sp\\u00e9cial Desserts": 2500, "Sp\\u00e9cial Jus": 9500, "Sp\\u00e9cial Ivoirienne": 41000}, "sales_by_item": [{"product_name": "Salade Panach\\u00e9e + Sosso", "category": "Sp\\u00e9cial Salade", "quantity": 3, "unit_price_xof": 4000, "total_ttc_xof": 12000}, {"product_name": "Atti\\u00e9k\\u00e9 + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 3, "unit_price_xof": 4000, "total_ttc_xof": 12000}, {"product_name": "Tchep + Mouton", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 3, "unit_price_xof": 3500, "total_ttc_xof": 10500}, {"product_name": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Salade", "quantity": 2, "unit_price_xof": 5000, "total_ttc_xof": 10000}, {"product_name": "Tchep + Poisson", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 3, "unit_price_xof": 3000, "total_ttc_xof": 9000}, {"product_name": "Couscous + Poulet", "category": "Sp\\u00e9cial Oriental", "quantity": 3, "unit_price_xof": 2500, "total_ttc_xof": 7500}, {"product_name": "Kabato Kope + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Kabato Dah + Poisson", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 3000, "total_ttc_xof": 6000}, {"product_name": "Kabato Dah + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Bissap", "category": "Sp\\u00e9cial Jus", "quantity": 10, "unit_price_xof": 500, "total_ttc_xof": 5000}, {"product_name": "Tchep + Poulet", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 2, "unit_price_xof": 2500, "total_ttc_xof": 5000}, {"product_name": "Igname bouillie + Poisson brais\\u00e9", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 5000, "total_ttc_xof": 5000}, {"product_name": "Petit pois + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 4500, "total_ttc_xof": 4500}, {"product_name": "Tamarin", "category": "Sp\\u00e9cial Jus", "quantity": 9, "unit_price_xof": 500, "total_ttc_xof": 4500}, {"product_name": "Igname bouillie + Sosso", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Couscous + Mouton", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Frites + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Sauce Dah + Mouton", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Igname frite + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Igname bouillie + Mouton", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Couscous + Poisson", "category": "Sp\\u00e9cial Oriental", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Sauce Feuille + Poisson", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Sauce L\\u00e9gume + Poisson", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 3000, "total_ttc_xof": 3000}, {"product_name": "Sauce Feuille + Poulet", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Alloco + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Atti\\u00e9k\\u00e9 + Poulet", "category": "Sp\\u00e9cial Ivoirienne", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Sauce L\\u00e9gume + Boeuf", "category": "Sp\\u00e9cial Sauce", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Dah + Tripe", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Lafri + Tripe", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Kope + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Yassa + Boeuf", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Salade de fruits", "category": "Sp\\u00e9cial Desserts", "quantity": 3, "unit_price_xof": 500, "total_ttc_xof": 1500}, {"product_name": "D\\u00e9gu\\u00e9", "category": "Sp\\u00e9cial Desserts", "quantity": 1, "unit_price_xof": 1000, "total_ttc_xof": 1000}], "cash_movements_in_xof": 25000, "cash_movements_out_xof": 0, "expected_cash_xof": 128000, "counted_cash_xof": 128000, "variance_xof": 0, "closing_breakdown": {"1000": 1, "2000": 1, "5000": 5, "10000": 10}, "orders_count": 14, "cancelled_orders_count": 0}	\N	2026-10-19 14:11:08.276008+00	2026-10-19 15:51:55.809398+00
a47b2f40-5c96-4b9e-9269-d673c78b5a50	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-20	CLOSED	50000	2026-10-20 11:29:31.86242+00	2026-10-20 16:42:20.665607+00	7	59500	59500	0	{"2000": 2, "5000": 1, "10000": 5, "coin_500": 1}	{"z_number": 7, "opening_float_xof": 50000, "total_sales_ttc_xof": 9500, "total_sales_ht_xof": 9500, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 9500}, "sales_by_category": {"Sp\\u00e9cial S\\u00e9n\\u00e9gal": 6000, "Sp\\u00e9cial Jus": 1000, "Sp\\u00e9cial Kabato": 2500}, "sales_by_item": [{"product_name": "Tchep + Mouton", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Tchep + Poulet", "category": "Sp\\u00e9cial S\\u00e9n\\u00e9gal", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Kabato Dah + Poulet", "category": "Sp\\u00e9cial Kabato", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Tamarin", "category": "Sp\\u00e9cial Jus", "quantity": 2, "unit_price_xof": 500, "total_ttc_xof": 1000}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 59500, "counted_cash_xof": 59500, "variance_xof": 0, "closing_breakdown": {"2000": 2, "5000": 1, "10000": 5, "coin_500": 1}, "orders_count": 2, "cancelled_orders_count": 0}	\N	2026-10-20 11:29:31.872441+00	2026-10-20 16:42:20.669908+00
db678c86-c0e1-4913-90ee-7d0ca403978e	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-21	CLOSED	50000	2026-10-21 09:40:59.531597+00	2026-10-22 10:52:04.430035+00	8	50000	50000	0	{"10000": 5}	{"z_number": 8, "opening_float_xof": 50000, "total_sales_ttc_xof": 0, "total_sales_ht_xof": 0, "total_sales_vat_xof": 0, "payments_by_method": {}, "sales_by_category": {}, "sales_by_item": [], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 50000, "counted_cash_xof": 50000, "variance_xof": 0, "closing_breakdown": {"10000": 5}, "orders_count": 0, "cancelled_orders_count": 0}	\N	2026-10-21 09:40:59.5355+00	2026-10-22 10:52:04.439055+00
cd0d53b5-fb69-40f5-bbbc-653961ec963e	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22	CLOSED	100000	2026-10-22 19:00:54.122359+00	2026-10-22 19:35:13.79745+00	9	110500	110500	0	{"500": 1, "10000": 11}	{"z_number": 9, "opening_float_xof": 100000, "total_sales_ttc_xof": 10500, "total_sales_ht_xof": 10500, "total_sales_vat_xof": 0, "payments_by_method": {"CASH": 10500}, "sales_by_category": {"Foufou / foutou": 3500, "Sp\\u00e9cial Salade": 6500, "Jus": 500}, "sales_by_item": [{"product_name": "Salade Panach\\u00e9e + Sosso", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 4000, "total_ttc_xof": 4000}, {"product_name": "Foufou/foutou faux brochet", "category": "Foufou / foutou", "quantity": 1, "unit_price_xof": 3500, "total_ttc_xof": 3500}, {"product_name": "Salade Panach\\u00e9e + Poulet", "category": "Sp\\u00e9cial Salade", "quantity": 1, "unit_price_xof": 2500, "total_ttc_xof": 2500}, {"product_name": "Jus de citron", "category": "Jus", "quantity": 1, "unit_price_xof": 500, "total_ttc_xof": 500}], "cash_movements_in_xof": 0, "cash_movements_out_xof": 0, "expected_cash_xof": 110500, "counted_cash_xof": 110500, "variance_xof": 0, "closing_breakdown": {"500": 1, "10000": 11}, "orders_count": 2, "cancelled_orders_count": 0}	\N	2026-10-22 19:00:54.151075+00	2026-10-22 19:35:13.806979+00
63d77089-d60c-446e-8363-bab14c8ca3d9	caisse-01	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	2026-10-23	OPEN	100000	2026-10-23 10:16:31.325321+00	\N	\N	\N	\N	\N	\N	\N	\N	2026-10-23 10:16:31.331971+00	2026-10-23 10:16:31.33198+00
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
8668c8b2-69a6-47ae-bece-9b80903790fa	0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c	c10971e6-af3a-444f-806d-419be5fc06c8	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Couscous + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-029", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Couscous + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-031", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Bissap", "quantity": 3, "amount": 500, "reference": "SYL-079", "measurementUnit": "U"}], "clientNcc": "9506466A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["a92d24c7-d36a-42c6-85e4-2b2d009b45e8", "ce4b412b-bb66-4375-b20e-22162f259ba7", "de4360df-4871-4dd9-b2d8-cb3a55dd40ab"]}	\N	\N	0	\N	2026-10-19 14:53:06.419166+00	2026-10-19 14:53:05.807021+00	2026-10-19 14:53:06.422056+00	FNE	B2B	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	\N	d7b73ea1-0364-446a-9ed8-86ce03817e5d	[{"order_item_id": "a92d24c7-d36a-42c6-85e4-2b2d009b45e8", "fne_item_id": "16b6d1b9-7040-484c-8669-05badf122741", "quantity": 1}, {"order_item_id": "ce4b412b-bb66-4375-b20e-22162f259ba7", "fne_item_id": "88570cfd-f75d-4074-8b89-29e352581330", "quantity": 1}, {"order_item_id": "de4360df-4871-4dd9-b2d8-cb3a55dd40ab", "fne_item_id": "e4d95955-b51e-4dd1-806e-4a4112e7f274", "quantity": 3}]	7500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000019	http://54.247.95.108/fr/verification/01a154a6-e55a-7223-9a60-70aab67bb784	{"ncc": "1304777N", "reference": "1304777N26000000019", "token": "http://54.247.95.108/fr/verification/01a154a6-e55a-7223-9a60-70aab67bb784", "warning": false, "balance_funds": 120120, "invoice": {"id": "d7b73ea1-0364-446a-9ed8-86ce03817e5d", "parentId": null, "parentReference": null, "token": "01a154a6-e55a-7223-9a60-70aab67bb784", "reference": "1304777N26000000019", "type": "invoice", "subtype": "normal", "date": "2026-10-19T14:53:06.208Z", "paymentMethod": "cash", "amount": 7500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 7500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 7500, "totalCustomTaxes": 0, "totalDue": 7500, "clientNcc": "9506466A", "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": null, "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS employeur", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-19T14:53:06.208Z", "updatedAt": "2026-10-19T14:53:06.208Z", "items": [{"id": "16b6d1b9-7040-484c-8669-05badf122741", "quantity": 1, "reference": "SYL-029", "description": "Couscous + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-19T14:53:06.208Z", "updatedAt": "2026-10-19T14:53:06.208Z", "taxes": [{"invoiceItemId": "16b6d1b9-7040-484c-8669-05badf122741", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:53:06.208Z", "updatedAt": "2026-10-19T14:53:06.208Z"}], "customTaxes": [], "invoiceId": "d7b73ea1-0364-446a-9ed8-86ce03817e5d", "parentId": null, "discount": null}, {"id": "88570cfd-f75d-4074-8b89-29e352581330", "quantity": 1, "reference": "SYL-031", "description": "Couscous + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-19T14:53:06.208Z", "updatedAt": "2026-10-19T14:53:06.208Z", "taxes": [{"invoiceItemId": "88570cfd-f75d-4074-8b89-29e352581330", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:53:06.208Z", "updatedAt": "2026-10-19T14:53:06.208Z"}], "customTaxes": [], "invoiceId": "d7b73ea1-0364-446a-9ed8-86ce03817e5d", "parentId": null, "discount": null}, {"id": "e4d95955-b51e-4dd1-806e-4a4112e7f274", "quantity": 3, "reference": "SYL-079", "description": "Bissap", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-19T14:53:06.208Z", "updatedAt": "2026-10-19T14:53:06.208Z", "taxes": [{"invoiceItemId": "e4d95955-b51e-4dd1-806e-4a4112e7f274", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:53:06.208Z", "updatedAt": "2026-10-19T14:53:06.208Z"}], "customTaxes": [], "invoiceId": "d7b73ea1-0364-446a-9ed8-86ce03817e5d", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
e59879dd-a76e-41ab-b208-313109c92899	cfdf234b-e450-4b8d-a49a-863dc774908e	c10971e6-af3a-444f-806d-419be5fc06c8	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Kabato Dah + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-005", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tchep + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-040", "measurementUnit": "U"}], "clientNcc": "9506466A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["aca05917-ddde-47f0-99ae-a66f3d4a5c00", "c17213e9-2f5a-4bed-accc-16c49fb91d85"]}	\N	\N	0	\N	2026-10-20 11:33:59.152387+00	2026-10-20 11:33:58.567141+00	2026-10-20 11:33:59.158255+00	FNE	B2B	a47b2f40-5c96-4b9e-9269-d673c78b5a50	\N	2d27f888-e18a-4e1f-8af4-081c4c50efc7	[{"order_item_id": "aca05917-ddde-47f0-99ae-a66f3d4a5c00", "fne_item_id": "775024f2-8e3a-42a8-aa30-c44371fea0c1", "quantity": 1}, {"order_item_id": "c17213e9-2f5a-4bed-accc-16c49fb91d85", "fne_item_id": "cc189e32-5aaa-43ef-a3ec-b1ac11acfec4", "quantity": 1}]	6000	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000020	http://54.247.95.108/fr/verification/01a15916-f474-7223-9a9f-15e2057c2667	{"ncc": "1304777N", "reference": "1304777N26000000020", "token": "http://54.247.95.108/fr/verification/01a15916-f474-7223-9a9f-15e2057c2667", "warning": false, "balance_funds": 120100, "invoice": {"id": "2d27f888-e18a-4e1f-8af4-081c4c50efc7", "parentId": null, "parentReference": null, "token": "01a15916-f474-7223-9a9f-15e2057c2667", "reference": "1304777N26000000020", "type": "invoice", "subtype": "normal", "date": "2026-10-20T11:33:58.989Z", "paymentMethod": "cash", "amount": 6000, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 6000, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 6000, "totalCustomTaxes": 0, "totalDue": 6000, "clientNcc": "9506466A", "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": null, "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS employeur", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-20T11:33:58.989Z", "updatedAt": "2026-10-20T11:33:58.989Z", "items": [{"id": "775024f2-8e3a-42a8-aa30-c44371fea0c1", "quantity": 1, "reference": "SYL-005", "description": "Kabato Dah + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-20T11:33:58.989Z", "updatedAt": "2026-10-20T11:33:58.989Z", "taxes": [{"invoiceItemId": "775024f2-8e3a-42a8-aa30-c44371fea0c1", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-20T11:33:58.989Z", "updatedAt": "2026-10-20T11:33:58.989Z"}], "customTaxes": [], "invoiceId": "2d27f888-e18a-4e1f-8af4-081c4c50efc7", "parentId": null, "discount": null}, {"id": "cc189e32-5aaa-43ef-a3ec-b1ac11acfec4", "quantity": 1, "reference": "SYL-040", "description": "Tchep + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-20T11:33:58.989Z", "updatedAt": "2026-10-20T11:33:58.989Z", "taxes": [{"invoiceItemId": "cc189e32-5aaa-43ef-a3ec-b1ac11acfec4", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-20T11:33:58.989Z", "updatedAt": "2026-10-20T11:33:58.989Z"}], "customTaxes": [], "invoiceId": "2d27f888-e18a-4e1f-8af4-081c4c50efc7", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
99de95c7-e757-4f90-b487-5dbc9159bdbd	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	a6e273be-5851-421a-96f2-a5b56ee678d1	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Kabato Kope + Poisson", "quantity": 1, "amount": 3000, "reference": "SYL-010", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Kabato Lafri + Tripe", "quantity": 1, "amount": 2500, "reference": "SYL-003", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "amount": 4000, "reference": "SYL-034", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Yassa + Boeuf", "quantity": 1, "amount": 2500, "reference": "SYL-041", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Bissap", "quantity": 1, "amount": 500, "reference": "SYL-079", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Passion", "quantity": 1, "amount": 1000, "reference": "SYL-078", "measurementUnit": "U"}], "clientNcc": "1254632A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["a467acd3-759c-497a-be87-091ce6c653b1", "972d450b-52f5-4ef9-8266-9c65babdf378", "c77f25ca-f040-46d8-afc9-696221641ae4", "3df78cc4-400b-4f7c-8de1-f74788ca3419", "85dea713-026e-4ed8-99fa-72a1e9604ee5", "3e607162-05f7-4db6-aea6-9ede78e3f561"]}	\N	\N	0	\N	2026-10-06 11:30:14.44347+00	2026-10-06 11:30:12.904792+00	2026-10-06 11:30:14.451264+00	FNE	B2B	61245d2f-8301-4acc-a965-12f74778b946	\N	8e92f48b-bdf2-49f7-bf37-4d1ad6cb2de5	[{"order_item_id": "a467acd3-759c-497a-be87-091ce6c653b1", "fne_item_id": "f6624018-8843-4cfc-9189-00ec02036669", "quantity": 1}, {"order_item_id": "972d450b-52f5-4ef9-8266-9c65babdf378", "fne_item_id": "558f81b1-5042-4d9e-b2e9-de184da2038f", "quantity": 1}, {"order_item_id": "c77f25ca-f040-46d8-afc9-696221641ae4", "fne_item_id": "a08f678c-ca44-4381-be16-4af6207ca8fc", "quantity": 1}, {"order_item_id": "3df78cc4-400b-4f7c-8de1-f74788ca3419", "fne_item_id": "f4f1e434-8108-49ca-9ef9-4165d505fa6a", "quantity": 1}, {"order_item_id": "85dea713-026e-4ed8-99fa-72a1e9604ee5", "fne_item_id": "f25c246b-c3ec-4a8f-94e0-181236c63937", "quantity": 1}, {"order_item_id": "3e607162-05f7-4db6-aea6-9ede78e3f561", "fne_item_id": "ffdcf25c-17a2-4a13-8c22-98190b62a6f2", "quantity": 1}]	13500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000004	http://54.247.95.108/fr/verification/01a110fa-7c94-7ffe-902f-14e1a0822292	{"ncc": "1304777N", "reference": "1304777N26000000004", "token": "http://54.247.95.108/fr/verification/01a110fa-7c94-7ffe-902f-14e1a0822292", "warning": false, "balance_funds": 20420, "invoice": {"id": "8e92f48b-bdf2-49f7-bf37-4d1ad6cb2de5", "parentId": null, "parentReference": null, "token": "01a110fa-7c94-7ffe-902f-14e1a0822292", "reference": "1304777N26000000004", "type": "invoice", "subtype": "normal", "date": "2026-10-06T11:30:13.344Z", "paymentMethod": "cash", "amount": 13500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 13500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 13500, "totalCustomTaxes": 0, "totalDue": 13500, "clientNcc": "1254632A", "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": "", "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS foncier", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z", "items": [{"id": "f6624018-8843-4cfc-9189-00ec02036669", "quantity": 1, "reference": "SYL-010", "description": "Kabato Kope + Poisson", "amount": 3000, "measurementUnit": "U", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z", "taxes": [{"invoiceItemId": "f6624018-8843-4cfc-9189-00ec02036669", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z"}], "customTaxes": [], "invoiceId": "8e92f48b-bdf2-49f7-bf37-4d1ad6cb2de5", "parentId": null, "discount": null}, {"id": "558f81b1-5042-4d9e-b2e9-de184da2038f", "quantity": 1, "reference": "SYL-003", "description": "Kabato Lafri + Tripe", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z", "taxes": [{"invoiceItemId": "558f81b1-5042-4d9e-b2e9-de184da2038f", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z"}], "customTaxes": [], "invoiceId": "8e92f48b-bdf2-49f7-bf37-4d1ad6cb2de5", "parentId": null, "discount": null}, {"id": "a08f678c-ca44-4381-be16-4af6207ca8fc", "quantity": 1, "reference": "SYL-034", "description": "Salade Panach\\u00e9e + Sosso", "amount": 4000, "measurementUnit": "U", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z", "taxes": [{"invoiceItemId": "a08f678c-ca44-4381-be16-4af6207ca8fc", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z"}], "customTaxes": [], "invoiceId": "8e92f48b-bdf2-49f7-bf37-4d1ad6cb2de5", "parentId": null, "discount": null}, {"id": "f4f1e434-8108-49ca-9ef9-4165d505fa6a", "quantity": 1, "reference": "SYL-041", "description": "Yassa + Boeuf", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z", "taxes": [{"invoiceItemId": "f4f1e434-8108-49ca-9ef9-4165d505fa6a", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z"}], "customTaxes": [], "invoiceId": "8e92f48b-bdf2-49f7-bf37-4d1ad6cb2de5", "parentId": null, "discount": null}, {"id": "f25c246b-c3ec-4a8f-94e0-181236c63937", "quantity": 1, "reference": "SYL-079", "description": "Bissap", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z", "taxes": [{"invoiceItemId": "f25c246b-c3ec-4a8f-94e0-181236c63937", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z"}], "customTaxes": [], "invoiceId": "8e92f48b-bdf2-49f7-bf37-4d1ad6cb2de5", "parentId": null, "discount": null}, {"id": "ffdcf25c-17a2-4a13-8c22-98190b62a6f2", "quantity": 1, "reference": "SYL-078", "description": "Passion", "amount": 1000, "measurementUnit": "U", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z", "taxes": [{"invoiceItemId": "ffdcf25c-17a2-4a13-8c22-98190b62a6f2", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T11:30:13.344Z", "updatedAt": "2026-10-06T11:30:13.344Z"}], "customTaxes": [], "invoiceId": "8e92f48b-bdf2-49f7-bf37-4d1ad6cb2de5", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
0df2ee1f-8933-4df2-b36e-febf38bc4465	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	c10971e6-af3a-444f-806d-419be5fc06c8	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Salade de fruits", "quantity": 1, "amount": 500, "reference": "SYL-077", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Frites + Poisson brais\\u00e9", "quantity": 1, "amount": 5000, "reference": "SYL-058", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Frites + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-056", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Atti\\u00e9k\\u00e9 + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-064", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Couscous + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-031", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Couscous + Boeuf", "quantity": 1, "amount": 2500, "reference": "SYL-028", "measurementUnit": "U"}], "clientNcc": "9506466A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["5c56d6c6-70f9-4dc5-9ec1-dcc68f39cb50", "1acb0446-8b20-4362-8689-b8c96f82d926", "9305284b-32d8-447f-9d80-46f6b143acf1", "db49c978-9039-4280-9fb2-9ba9b1839259", "10dc03af-0cf2-4220-a739-d794065840f6", "07633e84-d78c-4277-a497-dc062bbb5de7"]}	\N	\N	0	\N	2026-10-06 14:40:00.75532+00	2026-10-06 14:40:00.175441+00	2026-10-06 14:40:00.759683+00	FNE	B2B	61245d2f-8301-4acc-a965-12f74778b946	\N	8e7f2909-eff2-4e1a-9c45-19eb71ee9934	[{"order_item_id": "5c56d6c6-70f9-4dc5-9ec1-dcc68f39cb50", "fne_item_id": "39feb15d-efd5-4de0-86ac-e49903acff28", "quantity": 1}, {"order_item_id": "1acb0446-8b20-4362-8689-b8c96f82d926", "fne_item_id": "696b1c1a-c28a-4a75-8819-156237f5c932", "quantity": 1}, {"order_item_id": "9305284b-32d8-447f-9d80-46f6b143acf1", "fne_item_id": "88a6b3ec-e1e9-4792-a15b-1998bd1f0171", "quantity": 1}, {"order_item_id": "db49c978-9039-4280-9fb2-9ba9b1839259", "fne_item_id": "23d1fe15-6cbe-452d-bb05-4f485be1bd2f", "quantity": 1}, {"order_item_id": "10dc03af-0cf2-4220-a739-d794065840f6", "fne_item_id": "06b892f1-c6b8-4545-9b78-53853b07175c", "quantity": 1}, {"order_item_id": "07633e84-d78c-4277-a497-dc062bbb5de7", "fne_item_id": "dadf2add-3156-44c2-bdfe-128982fcf3b1", "quantity": 1}]	17500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000006	http://54.247.95.108/fr/verification/01a111a8-3c83-7ffe-9031-33b7fb3511d4	{"ncc": "1304777N", "reference": "1304777N26000000006", "token": "http://54.247.95.108/fr/verification/01a111a8-3c83-7ffe-9031-33b7fb3511d4", "warning": false, "balance_funds": 20380, "invoice": {"id": "8e7f2909-eff2-4e1a-9c45-19eb71ee9934", "parentId": null, "parentReference": null, "token": "01a111a8-3c83-7ffe-9031-33b7fb3511d4", "reference": "1304777N26000000006", "type": "invoice", "subtype": "normal", "date": "2026-10-06T14:40:00.574Z", "paymentMethod": "cash", "amount": 17500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 17500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 17500, "totalCustomTaxes": 0, "totalDue": 17500, "clientNcc": "9506466A", "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": null, "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS employeur", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z", "items": [{"id": "39feb15d-efd5-4de0-86ac-e49903acff28", "quantity": 1, "reference": "SYL-077", "description": "Salade de fruits", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z", "taxes": [{"invoiceItemId": "39feb15d-efd5-4de0-86ac-e49903acff28", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z"}], "customTaxes": [], "invoiceId": "8e7f2909-eff2-4e1a-9c45-19eb71ee9934", "parentId": null, "discount": null}, {"id": "696b1c1a-c28a-4a75-8819-156237f5c932", "quantity": 1, "reference": "SYL-058", "description": "Frites + Poisson brais\\u00e9", "amount": 5000, "measurementUnit": "U", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z", "taxes": [{"invoiceItemId": "696b1c1a-c28a-4a75-8819-156237f5c932", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z"}], "customTaxes": [], "invoiceId": "8e7f2909-eff2-4e1a-9c45-19eb71ee9934", "parentId": null, "discount": null}, {"id": "88a6b3ec-e1e9-4792-a15b-1998bd1f0171", "quantity": 1, "reference": "SYL-056", "description": "Frites + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z", "taxes": [{"invoiceItemId": "88a6b3ec-e1e9-4792-a15b-1998bd1f0171", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z"}], "customTaxes": [], "invoiceId": "8e7f2909-eff2-4e1a-9c45-19eb71ee9934", "parentId": null, "discount": null}, {"id": "23d1fe15-6cbe-452d-bb05-4f485be1bd2f", "quantity": 1, "reference": "SYL-064", "description": "Atti\\u00e9k\\u00e9 + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z", "taxes": [{"invoiceItemId": "23d1fe15-6cbe-452d-bb05-4f485be1bd2f", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z"}], "customTaxes": [], "invoiceId": "8e7f2909-eff2-4e1a-9c45-19eb71ee9934", "parentId": null, "discount": null}, {"id": "06b892f1-c6b8-4545-9b78-53853b07175c", "quantity": 1, "reference": "SYL-031", "description": "Couscous + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z", "taxes": [{"invoiceItemId": "06b892f1-c6b8-4545-9b78-53853b07175c", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z"}], "customTaxes": [], "invoiceId": "8e7f2909-eff2-4e1a-9c45-19eb71ee9934", "parentId": null, "discount": null}, {"id": "dadf2add-3156-44c2-bdfe-128982fcf3b1", "quantity": 1, "reference": "SYL-028", "description": "Couscous + Boeuf", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z", "taxes": [{"invoiceItemId": "dadf2add-3156-44c2-bdfe-128982fcf3b1", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T14:40:00.574Z", "updatedAt": "2026-10-06T14:40:00.574Z"}], "customTaxes": [], "invoiceId": "8e7f2909-eff2-4e1a-9c45-19eb71ee9934", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
565c9e2f-e823-45be-8088-2dc9868add27	21a1947c-5da6-4a14-ae3f-a931b866bb53	c10971e6-af3a-444f-806d-419be5fc06c8	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Kabato Lafri + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-006", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade de fruits", "quantity": 1, "amount": 500, "reference": "SYL-077", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Igname bouillie + Poisson brais\\u00e9", "quantity": 1, "amount": 5000, "reference": "SYL-048", "measurementUnit": "U"}], "clientNcc": "9506466A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["c2128174-33e6-43f8-b066-70fbf44d2a26", "6019f375-ed4a-4fa6-8512-8ba216d4305d", "446300e4-108f-4fb9-a437-295aa8a7627b"]}	\N	\N	0	\N	2026-10-08 11:16:21.448157+00	2026-10-08 11:16:20.847627+00	2026-10-08 11:16:21.474447+00	FNE	B2B	bec954fb-ce8e-4e82-b546-abecd853d1ac	\N	d13c344c-d5ab-46e5-ae16-49b06db9cb13	[{"order_item_id": "c2128174-33e6-43f8-b066-70fbf44d2a26", "fne_item_id": "5af3adfb-92cd-4919-81b5-705f47e7b24b", "quantity": 1}, {"order_item_id": "6019f375-ed4a-4fa6-8512-8ba216d4305d", "fne_item_id": "d93c5a1d-e074-46a4-9d5f-386a7e0074c8", "quantity": 1}, {"order_item_id": "446300e4-108f-4fb9-a437-295aa8a7627b", "fne_item_id": "332b278e-201b-436e-85c2-6f5a7fb60b12", "quantity": 1}]	8000	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000008	http://54.247.95.108/fr/verification/01a11b3a-80d1-7cc8-8f67-bde4788c6563	{"ncc": "1304777N", "reference": "1304777N26000000008", "token": "http://54.247.95.108/fr/verification/01a11b3a-80d1-7cc8-8f67-bde4788c6563", "warning": false, "balance_funds": 20340, "invoice": {"id": "d13c344c-d5ab-46e5-ae16-49b06db9cb13", "parentId": null, "parentReference": null, "token": "01a11b3a-80d1-7cc8-8f67-bde4788c6563", "reference": "1304777N26000000008", "type": "invoice", "subtype": "normal", "date": "2026-10-08T11:16:21.279Z", "paymentMethod": "cash", "amount": 8000, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 8000, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 8000, "totalCustomTaxes": 0, "totalDue": 8000, "clientNcc": "9506466A", "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": null, "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS employeur", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-08T11:16:21.279Z", "updatedAt": "2026-10-08T11:16:21.279Z", "items": [{"id": "5af3adfb-92cd-4919-81b5-705f47e7b24b", "quantity": 1, "reference": "SYL-006", "description": "Kabato Lafri + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-08T11:16:21.279Z", "updatedAt": "2026-10-08T11:16:21.279Z", "taxes": [{"invoiceItemId": "5af3adfb-92cd-4919-81b5-705f47e7b24b", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T11:16:21.279Z", "updatedAt": "2026-10-08T11:16:21.279Z"}], "customTaxes": [], "invoiceId": "d13c344c-d5ab-46e5-ae16-49b06db9cb13", "parentId": null, "discount": null}, {"id": "d93c5a1d-e074-46a4-9d5f-386a7e0074c8", "quantity": 1, "reference": "SYL-077", "description": "Salade de fruits", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-08T11:16:21.279Z", "updatedAt": "2026-10-08T11:16:21.279Z", "taxes": [{"invoiceItemId": "d93c5a1d-e074-46a4-9d5f-386a7e0074c8", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T11:16:21.279Z", "updatedAt": "2026-10-08T11:16:21.279Z"}], "customTaxes": [], "invoiceId": "d13c344c-d5ab-46e5-ae16-49b06db9cb13", "parentId": null, "discount": null}, {"id": "332b278e-201b-436e-85c2-6f5a7fb60b12", "quantity": 1, "reference": "SYL-048", "description": "Igname bouillie + Poisson brais\\u00e9", "amount": 5000, "measurementUnit": "U", "createdAt": "2026-10-08T11:16:21.279Z", "updatedAt": "2026-10-08T11:16:21.279Z", "taxes": [{"invoiceItemId": "332b278e-201b-436e-85c2-6f5a7fb60b12", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T11:16:21.279Z", "updatedAt": "2026-10-08T11:16:21.279Z"}], "customTaxes": [], "invoiceId": "d13c344c-d5ab-46e5-ae16-49b06db9cb13", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
80c86750-432c-4a02-8355-3ca68d64ab1c	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	a6e273be-5851-421a-96f2-a5b56ee678d1	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Frites + Poisson brais\\u00e9", "quantity": 1, "amount": 5000, "reference": "SYL-058", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade Panach\\u00e9e + Boeuf", "quantity": 1, "amount": 2500, "reference": "SYL-032", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tamarin", "quantity": 1, "amount": 500, "reference": "SYL-080", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Kabato Lafri + Boeuf", "quantity": 1, "amount": 2500, "reference": "SYL-009", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Kabato Lafri + Boeuf", "quantity": 1, "amount": 2500, "reference": "SYL-009", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Kabato Lafri + Boeuf", "quantity": 1, "amount": 2500, "reference": "SYL-009", "measurementUnit": "U"}], "clientNcc": "1254632A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["6a1c51f4-6477-4bf1-969d-6e160d91fc09", "05724252-3c5b-44a0-bd40-0cac6287d211", "1d75d76b-8dad-4410-83f1-b5e7e8935356", "0b5fbcdc-9fff-458a-a007-8790bfeadfd5", "d20fcd9b-d2a4-4dd4-8b89-c5acf2abe30c", "d753772c-3739-4002-aaeb-a760b062b921"]}	\N	\N	0	\N	2026-10-06 15:36:22.77173+00	2026-10-06 15:36:22.212758+00	2026-10-06 15:36:22.775719+00	FNE	B2B	61245d2f-8301-4acc-a965-12f74778b946	\N	1c3e6540-b29f-4882-a900-9752ceb77cb6	[{"order_item_id": "6a1c51f4-6477-4bf1-969d-6e160d91fc09", "fne_item_id": "e9f74391-a146-4c67-aa98-794b7c998da3", "quantity": 1}, {"order_item_id": "05724252-3c5b-44a0-bd40-0cac6287d211", "fne_item_id": "0542b254-b4d8-49c1-b799-9c1a362de37a", "quantity": 1}, {"order_item_id": "1d75d76b-8dad-4410-83f1-b5e7e8935356", "fne_item_id": "9e0a61b2-1561-4deb-ae2a-8dbed801278a", "quantity": 1}, {"order_item_id": "0b5fbcdc-9fff-458a-a007-8790bfeadfd5", "fne_item_id": "15f0f6b5-ff02-48e9-83e8-5a900c3a92d7", "quantity": 1}, {"order_item_id": "d20fcd9b-d2a4-4dd4-8b89-c5acf2abe30c", "fne_item_id": "d9fc12ee-8b8f-462a-86e4-684f0928d053", "quantity": 1}, {"order_item_id": "d753772c-3739-4002-aaeb-a760b062b921", "fne_item_id": "76ca6a7a-0b60-45e2-90f1-1757e036ae43", "quantity": 1}]	15500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000007	http://54.247.95.108/fr/verification/01a111db-d78b-7cc8-8f4c-921f1f1ba8b5	{"ncc": "1304777N", "reference": "1304777N26000000007", "token": "http://54.247.95.108/fr/verification/01a111db-d78b-7cc8-8f4c-921f1f1ba8b5", "warning": false, "balance_funds": 20360, "invoice": {"id": "1c3e6540-b29f-4882-a900-9752ceb77cb6", "parentId": null, "parentReference": null, "token": "01a111db-d78b-7cc8-8f4c-921f1f1ba8b5", "reference": "1304777N26000000007", "type": "invoice", "subtype": "normal", "date": "2026-10-06T15:36:22.611Z", "paymentMethod": "cash", "amount": 15500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 15500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 15500, "totalCustomTaxes": 0, "totalDue": 15500, "clientNcc": "1254632A", "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": "", "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS foncier", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z", "items": [{"id": "e9f74391-a146-4c67-aa98-794b7c998da3", "quantity": 1, "reference": "SYL-058", "description": "Frites + Poisson brais\\u00e9", "amount": 5000, "measurementUnit": "U", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z", "taxes": [{"invoiceItemId": "e9f74391-a146-4c67-aa98-794b7c998da3", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z"}], "customTaxes": [], "invoiceId": "1c3e6540-b29f-4882-a900-9752ceb77cb6", "parentId": null, "discount": null}, {"id": "0542b254-b4d8-49c1-b799-9c1a362de37a", "quantity": 1, "reference": "SYL-032", "description": "Salade Panach\\u00e9e + Boeuf", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z", "taxes": [{"invoiceItemId": "0542b254-b4d8-49c1-b799-9c1a362de37a", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z"}], "customTaxes": [], "invoiceId": "1c3e6540-b29f-4882-a900-9752ceb77cb6", "parentId": null, "discount": null}, {"id": "9e0a61b2-1561-4deb-ae2a-8dbed801278a", "quantity": 1, "reference": "SYL-080", "description": "Tamarin", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z", "taxes": [{"invoiceItemId": "9e0a61b2-1561-4deb-ae2a-8dbed801278a", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z"}], "customTaxes": [], "invoiceId": "1c3e6540-b29f-4882-a900-9752ceb77cb6", "parentId": null, "discount": null}, {"id": "15f0f6b5-ff02-48e9-83e8-5a900c3a92d7", "quantity": 1, "reference": "SYL-009", "description": "Kabato Lafri + Boeuf", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z", "taxes": [{"invoiceItemId": "15f0f6b5-ff02-48e9-83e8-5a900c3a92d7", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z"}], "customTaxes": [], "invoiceId": "1c3e6540-b29f-4882-a900-9752ceb77cb6", "parentId": null, "discount": null}, {"id": "d9fc12ee-8b8f-462a-86e4-684f0928d053", "quantity": 1, "reference": "SYL-009", "description": "Kabato Lafri + Boeuf", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z", "taxes": [{"invoiceItemId": "d9fc12ee-8b8f-462a-86e4-684f0928d053", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z"}], "customTaxes": [], "invoiceId": "1c3e6540-b29f-4882-a900-9752ceb77cb6", "parentId": null, "discount": null}, {"id": "76ca6a7a-0b60-45e2-90f1-1757e036ae43", "quantity": 1, "reference": "SYL-009", "description": "Kabato Lafri + Boeuf", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z", "taxes": [{"invoiceItemId": "76ca6a7a-0b60-45e2-90f1-1757e036ae43", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-06T15:36:22.611Z", "updatedAt": "2026-10-06T15:36:22.611Z"}], "customTaxes": [], "invoiceId": "1c3e6540-b29f-4882-a900-9752ceb77cb6", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
926e5779-7412-40bf-83ab-b6da6630b40e	1ae79c99-2c11-40f4-9b4e-6948b5256aed	a6e273be-5851-421a-96f2-a5b56ee678d1	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Frites + Boeuf", "quantity": 1, "amount": 2500, "reference": "SYL-055", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Atti\\u00e9k\\u00e9 + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-061", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Igname frite + Poisson brais\\u00e9", "quantity": 1, "amount": 5000, "reference": "SYL-053", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Alloco + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-066", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "D\\u00e9gu\\u00e9", "quantity": 1, "amount": 1000, "reference": "SYL-076", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade de fruits", "quantity": 1, "amount": 500, "reference": "SYL-077", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Lait", "quantity": 1, "amount": 1000, "reference": "SYL-075", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tamarin", "quantity": 1, "amount": 500, "reference": "SYL-080", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Passion", "quantity": 1, "amount": 1000, "reference": "SYL-078", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Bissap", "quantity": 2, "amount": 500, "reference": "SYL-079", "measurementUnit": "U"}], "clientNcc": "1254632A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["46e136ee-bbf7-4b07-943e-2e3977562cf6", "c77bbda0-02d1-406b-8574-635b5f91e893", "a6b0a7ef-5441-4612-8bff-481292fa3917", "34ae8946-65cb-4182-a54b-cb1da219dd5b", "6db34d42-4166-4d91-9cab-5975584a5ab6", "a3fd6878-a50a-4a7b-88b3-6fa9b14945e0", "7ce53cf8-fbfd-4792-8ed2-e96b388a31c6", "1702ffc1-934d-4b8b-acfc-7e72de785bf5", "93069097-ee32-4d2c-a7c1-efbc6471764c", "16f28926-701a-443d-8ca1-d7203764e656"]}	\N	\N	0	\N	2026-10-08 14:46:13.139672+00	2026-10-08 14:46:12.442952+00	2026-10-08 14:46:13.145182+00	FNE	B2B	bec954fb-ce8e-4e82-b546-abecd853d1ac	\N	4677a7a1-1386-4cd0-a1f2-7e59d8871e8f	[{"order_item_id": "46e136ee-bbf7-4b07-943e-2e3977562cf6", "fne_item_id": "a86586a2-dc46-40d0-beb6-de39b240efe6", "quantity": 1}, {"order_item_id": "c77bbda0-02d1-406b-8574-635b5f91e893", "fne_item_id": "a10a34d5-af3f-44bc-a6a0-ac6f0ecbf611", "quantity": 1}, {"order_item_id": "a6b0a7ef-5441-4612-8bff-481292fa3917", "fne_item_id": "93bbd0ca-163d-41b1-8243-d0ab02fce26f", "quantity": 1}, {"order_item_id": "34ae8946-65cb-4182-a54b-cb1da219dd5b", "fne_item_id": "4f2f21f5-be40-4945-a865-69e64bead687", "quantity": 1}, {"order_item_id": "6db34d42-4166-4d91-9cab-5975584a5ab6", "fne_item_id": "ec467a2c-1afd-4f69-8ccd-87a8b535daa4", "quantity": 1}, {"order_item_id": "a3fd6878-a50a-4a7b-88b3-6fa9b14945e0", "fne_item_id": "6c197c5f-cd40-4bf1-a196-8d9142115bb0", "quantity": 1}, {"order_item_id": "7ce53cf8-fbfd-4792-8ed2-e96b388a31c6", "fne_item_id": "5a744bbe-f65b-4e88-8241-834d4c4535cc", "quantity": 1}, {"order_item_id": "1702ffc1-934d-4b8b-acfc-7e72de785bf5", "fne_item_id": "1cb164d4-d9cd-4839-a770-3c29ee0a6a31", "quantity": 1}, {"order_item_id": "93069097-ee32-4d2c-a7c1-efbc6471764c", "fne_item_id": "aafd324a-41aa-442f-9d68-e98e0062a572", "quantity": 1}, {"order_item_id": "16f28926-701a-443d-8ca1-d7203764e656", "fne_item_id": "23d3fcc3-85b5-4ac1-816d-500b1129f8c5", "quantity": 2}]	17500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000009	http://54.247.95.108/fr/verification/01a11bfa-a2ce-7cc8-8f7e-4a46deabfc12	{"ncc": "1304777N", "reference": "1304777N26000000009", "token": "http://54.247.95.108/fr/verification/01a11bfa-a2ce-7cc8-8f7e-4a46deabfc12", "warning": false, "balance_funds": 20320, "invoice": {"id": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "parentReference": null, "token": "01a11bfa-a2ce-7cc8-8f7e-4a46deabfc12", "reference": "1304777N26000000009", "type": "invoice", "subtype": "normal", "date": "2026-10-08T14:46:12.856Z", "paymentMethod": "cash", "amount": 17500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 17500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 17500, "totalCustomTaxes": 0, "totalDue": 17500, "clientNcc": "1254632A", "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": "", "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS foncier", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "items": [{"id": "a86586a2-dc46-40d0-beb6-de39b240efe6", "quantity": 1, "reference": "SYL-055", "description": "Frites + Boeuf", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "a86586a2-dc46-40d0-beb6-de39b240efe6", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "a10a34d5-af3f-44bc-a6a0-ac6f0ecbf611", "quantity": 1, "reference": "SYL-061", "description": "Atti\\u00e9k\\u00e9 + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "a10a34d5-af3f-44bc-a6a0-ac6f0ecbf611", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "93bbd0ca-163d-41b1-8243-d0ab02fce26f", "quantity": 1, "reference": "SYL-053", "description": "Igname frite + Poisson brais\\u00e9", "amount": 5000, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "93bbd0ca-163d-41b1-8243-d0ab02fce26f", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "4f2f21f5-be40-4945-a865-69e64bead687", "quantity": 1, "reference": "SYL-066", "description": "Alloco + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "4f2f21f5-be40-4945-a865-69e64bead687", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "ec467a2c-1afd-4f69-8ccd-87a8b535daa4", "quantity": 1, "reference": "SYL-076", "description": "D\\u00e9gu\\u00e9", "amount": 1000, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "ec467a2c-1afd-4f69-8ccd-87a8b535daa4", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "6c197c5f-cd40-4bf1-a196-8d9142115bb0", "quantity": 1, "reference": "SYL-077", "description": "Salade de fruits", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "6c197c5f-cd40-4bf1-a196-8d9142115bb0", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "5a744bbe-f65b-4e88-8241-834d4c4535cc", "quantity": 1, "reference": "SYL-075", "description": "Lait", "amount": 1000, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "5a744bbe-f65b-4e88-8241-834d4c4535cc", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "1cb164d4-d9cd-4839-a770-3c29ee0a6a31", "quantity": 1, "reference": "SYL-080", "description": "Tamarin", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "1cb164d4-d9cd-4839-a770-3c29ee0a6a31", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "aafd324a-41aa-442f-9d68-e98e0062a572", "quantity": 1, "reference": "SYL-078", "description": "Passion", "amount": 1000, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "aafd324a-41aa-442f-9d68-e98e0062a572", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}, {"id": "23d3fcc3-85b5-4ac1-816d-500b1129f8c5", "quantity": 2, "reference": "SYL-079", "description": "Bissap", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z", "taxes": [{"invoiceItemId": "23d3fcc3-85b5-4ac1-816d-500b1129f8c5", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T14:46:12.856Z", "updatedAt": "2026-10-08T14:46:12.856Z"}], "customTaxes": [], "invoiceId": "4677a7a1-1386-4cd0-a1f2-7e59d8871e8f", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
a00c63dd-ab30-477f-a178-d05915f28023	e6ff5588-1a97-409f-b651-8dcd1ec5135b	\N	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2C", "isRne": false, "clientCompanyName": "CLIENT DIVERS", "clientPhone": "0748735573", "clientEmail": "restaurantmykpro@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Kabato Dah + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-005", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Kabato Dah + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-014", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Kabato Kope + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-013", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tamarin", "quantity": 1, "amount": 500, "reference": "SYL-080", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Bissap", "quantity": 3, "amount": 500, "reference": "SYL-079", "measurementUnit": "U"}], "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["a875f631-1aad-41ac-b5ef-d4e9e8b5116b", "151ad44b-07ca-4c27-a654-0323faa9847b", "4378c8a6-422e-4960-9b3b-2ac2b0b1a352", "e3fab71b-b539-4ba7-bb7d-7dbcab053644", "93692203-4e85-4e26-b2d5-a5e8308eed51"]}	\N	\N	0	\N	2026-10-08 15:13:45.091865+00	2026-10-08 15:13:44.479172+00	2026-10-08 15:13:45.09824+00	FNE	B2C	bec954fb-ce8e-4e82-b546-abecd853d1ac	\N	050fd440-0f60-4bd5-b669-5452d54f101f	[{"order_item_id": "a875f631-1aad-41ac-b5ef-d4e9e8b5116b", "fne_item_id": "7080fe4d-a731-4e04-8574-a7da50f3efb7", "quantity": 1}, {"order_item_id": "151ad44b-07ca-4c27-a654-0323faa9847b", "fne_item_id": "1a3b80ff-01e5-4dd9-9348-3d3b7b1e9c00", "quantity": 1}, {"order_item_id": "4378c8a6-422e-4960-9b3b-2ac2b0b1a352", "fne_item_id": "47e52915-85aa-471c-b6ed-bbc52587533d", "quantity": 1}, {"order_item_id": "e3fab71b-b539-4ba7-bb7d-7dbcab053644", "fne_item_id": "a6bd0987-3012-48ba-8ec6-fcdf71b2d192", "quantity": 1}, {"order_item_id": "93692203-4e85-4e26-b2d5-a5e8308eed51", "fne_item_id": "f111fadb-724e-4163-a93e-61557b813d9d", "quantity": 3}]	11500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000010	http://54.247.95.108/fr/verification/01a11c13-d7ef-7cc8-8f7e-a99af004de76	{"ncc": "1304777N", "reference": "1304777N26000000010", "token": "http://54.247.95.108/fr/verification/01a11c13-d7ef-7cc8-8f7e-a99af004de76", "warning": false, "balance_funds": 20300, "invoice": {"id": "050fd440-0f60-4bd5-b669-5452d54f101f", "parentId": null, "parentReference": null, "token": "01a11c13-d7ef-7cc8-8f7e-a99af004de76", "reference": "1304777N26000000010", "type": "invoice", "subtype": "normal", "date": "2026-10-08T15:13:44.876Z", "paymentMethod": "cash", "amount": 11500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 11500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 11500, "totalCustomTaxes": 0, "totalDue": 11500, "clientNcc": null, "clientCompanyName": "CLIENT DIVERS", "clientPhone": "0748735573", "clientEmail": "restaurantmykpro@gmail.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": null, "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": null, "status": "paid", "template": "B2C", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z", "items": [{"id": "7080fe4d-a731-4e04-8574-a7da50f3efb7", "quantity": 1, "reference": "SYL-005", "description": "Kabato Dah + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z", "taxes": [{"invoiceItemId": "7080fe4d-a731-4e04-8574-a7da50f3efb7", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z"}], "customTaxes": [], "invoiceId": "050fd440-0f60-4bd5-b669-5452d54f101f", "parentId": null, "discount": null}, {"id": "1a3b80ff-01e5-4dd9-9348-3d3b7b1e9c00", "quantity": 1, "reference": "SYL-014", "description": "Kabato Dah + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z", "taxes": [{"invoiceItemId": "1a3b80ff-01e5-4dd9-9348-3d3b7b1e9c00", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z"}], "customTaxes": [], "invoiceId": "050fd440-0f60-4bd5-b669-5452d54f101f", "parentId": null, "discount": null}, {"id": "47e52915-85aa-471c-b6ed-bbc52587533d", "quantity": 1, "reference": "SYL-013", "description": "Kabato Kope + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z", "taxes": [{"invoiceItemId": "47e52915-85aa-471c-b6ed-bbc52587533d", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z"}], "customTaxes": [], "invoiceId": "050fd440-0f60-4bd5-b669-5452d54f101f", "parentId": null, "discount": null}, {"id": "a6bd0987-3012-48ba-8ec6-fcdf71b2d192", "quantity": 1, "reference": "SYL-080", "description": "Tamarin", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z", "taxes": [{"invoiceItemId": "a6bd0987-3012-48ba-8ec6-fcdf71b2d192", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z"}], "customTaxes": [], "invoiceId": "050fd440-0f60-4bd5-b669-5452d54f101f", "parentId": null, "discount": null}, {"id": "f111fadb-724e-4163-a93e-61557b813d9d", "quantity": 3, "reference": "SYL-079", "description": "Bissap", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z", "taxes": [{"invoiceItemId": "f111fadb-724e-4163-a93e-61557b813d9d", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-08T15:13:44.876Z", "updatedAt": "2026-10-08T15:13:44.876Z"}], "customTaxes": [], "invoiceId": "050fd440-0f60-4bd5-b669-5452d54f101f", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
336935f0-b189-4e84-b83a-c426bff0c33e	722b3daf-c534-4a28-96a1-c7f866dcb6e4	c10971e6-af3a-444f-806d-419be5fc06c8	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Tchep + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-040", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tchep + Poisson", "quantity": 1, "amount": 3000, "reference": "SYL-039", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tamarin", "quantity": 1, "amount": 500, "reference": "SYL-080", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Bissap", "quantity": 1, "amount": 500, "reference": "SYL-079", "measurementUnit": "U"}], "clientNcc": "9506466A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["83dca401-8acc-4269-9260-ad3a9c28a80f", "04dde75d-0a3f-49ba-9381-1794cc5942af", "213f00dd-8b39-4ce9-b94f-7abcdcb0e2a4", "3e7be164-b550-4bf0-acb8-086d7e054200"]}	\N	\N	0	\N	2026-10-16 10:02:00.980645+00	2026-10-16 10:02:00.378256+00	2026-10-16 10:02:00.994627+00	FNE	B2B	0e8d76cb-c7be-43a9-9975-18ecfb230858	\N	33bce49c-ce03-4e32-8242-556cca33ae45	[{"order_item_id": "83dca401-8acc-4269-9260-ad3a9c28a80f", "fne_item_id": "1048933c-1cce-47aa-a4da-7a358b7f9a71", "quantity": 1}, {"order_item_id": "04dde75d-0a3f-49ba-9381-1794cc5942af", "fne_item_id": "a3d1cfcf-c69c-4873-9b76-096a7507bdfb", "quantity": 1}, {"order_item_id": "213f00dd-8b39-4ce9-b94f-7abcdcb0e2a4", "fne_item_id": "013f44b4-9ab9-4354-9ff1-fe2c8d8c9019", "quantity": 1}, {"order_item_id": "3e7be164-b550-4bf0-acb8-086d7e054200", "fne_item_id": "aba1569b-8355-42a1-b59d-f7852d25e824", "quantity": 1}]	7500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000016	http://54.247.95.108/fr/verification/01a14429-50ee-7eed-8cee-984840f2f730	{"ncc": "1304777N", "reference": "1304777N26000000016", "token": "http://54.247.95.108/fr/verification/01a14429-50ee-7eed-8cee-984840f2f730", "warning": false, "balance_funds": 120180, "invoice": {"id": "33bce49c-ce03-4e32-8242-556cca33ae45", "parentId": null, "parentReference": null, "token": "01a14429-50ee-7eed-8cee-984840f2f730", "reference": "1304777N26000000016", "type": "invoice", "subtype": "normal", "date": "2026-10-16T10:02:00.751Z", "paymentMethod": "cash", "amount": 7500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 7500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 7500, "totalCustomTaxes": 0, "totalDue": 7500, "clientNcc": "9506466A", "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": null, "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS employeur", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z", "items": [{"id": "1048933c-1cce-47aa-a4da-7a358b7f9a71", "quantity": 1, "reference": "SYL-040", "description": "Tchep + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z", "taxes": [{"invoiceItemId": "1048933c-1cce-47aa-a4da-7a358b7f9a71", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z"}], "customTaxes": [], "invoiceId": "33bce49c-ce03-4e32-8242-556cca33ae45", "parentId": null, "discount": null}, {"id": "a3d1cfcf-c69c-4873-9b76-096a7507bdfb", "quantity": 1, "reference": "SYL-039", "description": "Tchep + Poisson", "amount": 3000, "measurementUnit": "U", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z", "taxes": [{"invoiceItemId": "a3d1cfcf-c69c-4873-9b76-096a7507bdfb", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z"}], "customTaxes": [], "invoiceId": "33bce49c-ce03-4e32-8242-556cca33ae45", "parentId": null, "discount": null}, {"id": "013f44b4-9ab9-4354-9ff1-fe2c8d8c9019", "quantity": 1, "reference": "SYL-080", "description": "Tamarin", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z", "taxes": [{"invoiceItemId": "013f44b4-9ab9-4354-9ff1-fe2c8d8c9019", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z"}], "customTaxes": [], "invoiceId": "33bce49c-ce03-4e32-8242-556cca33ae45", "parentId": null, "discount": null}, {"id": "aba1569b-8355-42a1-b59d-f7852d25e824", "quantity": 1, "reference": "SYL-079", "description": "Bissap", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z", "taxes": [{"invoiceItemId": "aba1569b-8355-42a1-b59d-f7852d25e824", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-16T10:02:00.751Z", "updatedAt": "2026-10-16T10:02:00.751Z"}], "customTaxes": [], "invoiceId": "33bce49c-ce03-4e32-8242-556cca33ae45", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
60998ea0-4546-437f-bddf-a6ed70c492ca	c7b4ce76-37d6-4963-83b6-5da7c270aa02	a6e273be-5851-421a-96f2-a5b56ee678d1	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "mobile-money", "template": "B2B", "isRne": false, "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Sauce Feuille + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-019", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tamarin", "quantity": 1, "amount": 500, "reference": "SYL-080", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Sauce L\\u00e9gume + Poisson", "quantity": 1, "amount": 3000, "reference": "SYL-026", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Bissap", "quantity": 1, "amount": 500, "reference": "SYL-079", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Sauce Dah + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-021", "measurementUnit": "U"}], "clientNcc": "1254632A", "clientSellerName": "Digui Thio"}, "payment_method": "MOBILE_MONEY", "order_item_ids": ["1f1d6002-b9ff-4446-92e0-5d144050e407", "ab726aff-b107-4730-9b4d-2d2731937b56", "f81254a9-7d59-4854-a8c4-fded26287cfd", "7f941c08-f4bd-43a8-9552-bbf86db49fa3", "135fff4f-cfed-4dee-bb68-00c99c0986eb"]}	\N	\N	0	\N	2026-10-13 12:20:41.658483+00	2026-10-13 12:20:41.247365+00	2026-10-13 12:20:41.663815+00	FNE	B2B	534d40ba-7ee4-47ac-93a0-080192232503	\N	739a016a-3b8a-4b8c-87ca-eb3ae3f242d3	[{"order_item_id": "1f1d6002-b9ff-4446-92e0-5d144050e407", "fne_item_id": "d0ae7ab8-2c0b-46a4-a9fe-7e5d8820f11f", "quantity": 1}, {"order_item_id": "ab726aff-b107-4730-9b4d-2d2731937b56", "fne_item_id": "eabad9c9-c7bd-4461-b85e-6e8e5c852274", "quantity": 1}, {"order_item_id": "f81254a9-7d59-4854-a8c4-fded26287cfd", "fne_item_id": "40dad194-2d48-4a1f-bc98-1884124a888e", "quantity": 1}, {"order_item_id": "7f941c08-f4bd-43a8-9552-bbf86db49fa3", "fne_item_id": "f8fb6aad-25f5-48be-a158-552d75256c82", "quantity": 1}, {"order_item_id": "135fff4f-cfed-4dee-bb68-00c99c0986eb", "fne_item_id": "0842bfdc-ff69-443b-b927-dc5a1f8f051c", "quantity": 1}]	10000	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000011	http://54.247.95.108/fr/verification/01a13535-33d8-7eed-8c9a-2998e3217b42	{"ncc": "1304777N", "reference": "1304777N26000000011", "token": "http://54.247.95.108/fr/verification/01a13535-33d8-7eed-8c9a-2998e3217b42", "warning": false, "balance_funds": 120280, "invoice": {"id": "739a016a-3b8a-4b8c-87ca-eb3ae3f242d3", "parentId": null, "parentReference": null, "token": "01a13535-33d8-7eed-8c9a-2998e3217b42", "reference": "1304777N26000000011", "type": "invoice", "subtype": "normal", "date": "2026-10-13T12:20:41.520Z", "paymentMethod": "mobile-money", "amount": 10000, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 10000, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 10000, "totalCustomTaxes": 0, "totalDue": 10000, "clientNcc": "1254632A", "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": "", "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS foncier", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z", "items": [{"id": "d0ae7ab8-2c0b-46a4-a9fe-7e5d8820f11f", "quantity": 1, "reference": "SYL-019", "description": "Sauce Feuille + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z", "taxes": [{"invoiceItemId": "d0ae7ab8-2c0b-46a4-a9fe-7e5d8820f11f", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z"}], "customTaxes": [], "invoiceId": "739a016a-3b8a-4b8c-87ca-eb3ae3f242d3", "parentId": null, "discount": null}, {"id": "eabad9c9-c7bd-4461-b85e-6e8e5c852274", "quantity": 1, "reference": "SYL-080", "description": "Tamarin", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z", "taxes": [{"invoiceItemId": "eabad9c9-c7bd-4461-b85e-6e8e5c852274", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z"}], "customTaxes": [], "invoiceId": "739a016a-3b8a-4b8c-87ca-eb3ae3f242d3", "parentId": null, "discount": null}, {"id": "40dad194-2d48-4a1f-bc98-1884124a888e", "quantity": 1, "reference": "SYL-026", "description": "Sauce L\\u00e9gume + Poisson", "amount": 3000, "measurementUnit": "U", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z", "taxes": [{"invoiceItemId": "40dad194-2d48-4a1f-bc98-1884124a888e", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z"}], "customTaxes": [], "invoiceId": "739a016a-3b8a-4b8c-87ca-eb3ae3f242d3", "parentId": null, "discount": null}, {"id": "f8fb6aad-25f5-48be-a158-552d75256c82", "quantity": 1, "reference": "SYL-079", "description": "Bissap", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z", "taxes": [{"invoiceItemId": "f8fb6aad-25f5-48be-a158-552d75256c82", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z"}], "customTaxes": [], "invoiceId": "739a016a-3b8a-4b8c-87ca-eb3ae3f242d3", "parentId": null, "discount": null}, {"id": "0842bfdc-ff69-443b-b927-dc5a1f8f051c", "quantity": 1, "reference": "SYL-021", "description": "Sauce Dah + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z", "taxes": [{"invoiceItemId": "0842bfdc-ff69-443b-b927-dc5a1f8f051c", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T12:20:41.520Z", "updatedAt": "2026-10-13T12:20:41.520Z"}], "customTaxes": [], "invoiceId": "739a016a-3b8a-4b8c-87ca-eb3ae3f242d3", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
2803b7c7-2a16-42f3-ac21-b139ef95dc02	e39da534-1326-47b7-a6e2-b3bdccfbd904	c10971e6-af3a-444f-806d-419be5fc06c8	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Kabato Lafri + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-006", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Bissap", "quantity": 1, "amount": 500, "reference": "SYL-079", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tamarin", "quantity": 1, "amount": 500, "reference": "SYL-080", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Couscous + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-029", "measurementUnit": "U"}], "clientNcc": "9506466A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["a18a82f7-702b-4064-8732-461c7c043f31", "3887aaf8-a5c8-4e05-abbc-b6f9a9d6ab3c", "684b573e-627c-4a7f-9e71-6465004fa91d", "4e2a14ab-cc7c-4812-a9e2-24601fde4a6b"]}	\N	\N	0	\N	2026-10-13 14:56:02.140799+00	2026-10-13 14:56:01.377944+00	2026-10-13 14:56:02.145638+00	FNE	B2B	534d40ba-7ee4-47ac-93a0-080192232503	\N	86cfb860-5371-4246-a5d7-3637b646d7c8	[{"order_item_id": "a18a82f7-702b-4064-8732-461c7c043f31", "fne_item_id": "1ed16660-25db-4063-8d3f-4d10c712381c", "quantity": 1}, {"order_item_id": "3887aaf8-a5c8-4e05-abbc-b6f9a9d6ab3c", "fne_item_id": "8ef0f7d0-5aa8-4ec9-ae0c-c08e15bf0c8a", "quantity": 1}, {"order_item_id": "684b573e-627c-4a7f-9e71-6465004fa91d", "fne_item_id": "05f2c5e2-fa32-4d48-9572-63dd94366495", "quantity": 1}, {"order_item_id": "4e2a14ab-cc7c-4812-a9e2-24601fde4a6b", "fne_item_id": "ab19c7c9-b165-404c-976b-67fab22434af", "quantity": 1}]	6000	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000012	http://54.247.95.108/fr/verification/01a135c3-6ba4-7223-99ef-8622b369e98f	{"ncc": "1304777N", "reference": "1304777N26000000012", "token": "http://54.247.95.108/fr/verification/01a135c3-6ba4-7223-99ef-8622b369e98f", "warning": false, "balance_funds": 120260, "invoice": {"id": "86cfb860-5371-4246-a5d7-3637b646d7c8", "parentId": null, "parentReference": null, "token": "01a135c3-6ba4-7223-99ef-8622b369e98f", "reference": "1304777N26000000012", "type": "invoice", "subtype": "normal", "date": "2026-10-13T14:56:01.757Z", "paymentMethod": "cash", "amount": 6000, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 6000, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 6000, "totalCustomTaxes": 0, "totalDue": 6000, "clientNcc": "9506466A", "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": null, "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS employeur", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z", "items": [{"id": "1ed16660-25db-4063-8d3f-4d10c712381c", "quantity": 1, "reference": "SYL-006", "description": "Kabato Lafri + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z", "taxes": [{"invoiceItemId": "1ed16660-25db-4063-8d3f-4d10c712381c", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z"}], "customTaxes": [], "invoiceId": "86cfb860-5371-4246-a5d7-3637b646d7c8", "parentId": null, "discount": null}, {"id": "8ef0f7d0-5aa8-4ec9-ae0c-c08e15bf0c8a", "quantity": 1, "reference": "SYL-079", "description": "Bissap", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z", "taxes": [{"invoiceItemId": "8ef0f7d0-5aa8-4ec9-ae0c-c08e15bf0c8a", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z"}], "customTaxes": [], "invoiceId": "86cfb860-5371-4246-a5d7-3637b646d7c8", "parentId": null, "discount": null}, {"id": "05f2c5e2-fa32-4d48-9572-63dd94366495", "quantity": 1, "reference": "SYL-080", "description": "Tamarin", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z", "taxes": [{"invoiceItemId": "05f2c5e2-fa32-4d48-9572-63dd94366495", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z"}], "customTaxes": [], "invoiceId": "86cfb860-5371-4246-a5d7-3637b646d7c8", "parentId": null, "discount": null}, {"id": "ab19c7c9-b165-404c-976b-67fab22434af", "quantity": 1, "reference": "SYL-029", "description": "Couscous + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z", "taxes": [{"invoiceItemId": "ab19c7c9-b165-404c-976b-67fab22434af", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-13T14:56:01.757Z", "updatedAt": "2026-10-13T14:56:01.757Z"}], "customTaxes": [], "invoiceId": "86cfb860-5371-4246-a5d7-3637b646d7c8", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
7f042d15-8463-4e26-9c0e-0ab5a61084c5	998f84b2-586b-47c9-98ce-bcd1becca088	a6e273be-5851-421a-96f2-a5b56ee678d1	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Igname bouillie + Poisson brais\\u00e9", "quantity": 1, "amount": 5000, "reference": "SYL-048", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tchep + Poisson", "quantity": 1, "amount": 3000, "reference": "SYL-039", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "quantity": 1, "amount": 5000, "reference": "SYL-035", "measurementUnit": "U"}], "clientNcc": "1254632A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["e0cc0c69-f1c3-4507-8c36-48b5a865dd3c", "3076529a-b556-457b-94de-0135c6483259", "d247412b-4251-43ed-aa65-3915ea1c1b0d"]}	\N	\N	0	\N	2026-10-15 10:16:18.53526+00	2026-10-14 15:23:47.085623+00	2026-10-15 10:16:18.65638+00	FNE	B2B	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	\N	\N	\N	\N	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000013	http://54.247.95.108/fr/invoice-management/view/4101bdef-b877-40bb-a08c-3199f2e0ba92	\N	1	FneUncertainError: issue inconnue : ReadTimeout('timed out')	\N
879d36bd-6fa6-4206-8275-b6f83caf77ac	1d99a39f-4263-4b0f-b6dd-6544080aab4a	a6e273be-5851-421a-96f2-a5b56ee678d1	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Tchep + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-040", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "amount": 4000, "reference": "SYL-034", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade de fruits", "quantity": 1, "amount": 500, "reference": "SYL-077", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Bissap", "quantity": 1, "amount": 500, "reference": "SYL-079", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Passion", "quantity": 1, "amount": 1000, "reference": "SYL-078", "measurementUnit": "U"}], "clientNcc": "1254632A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["38b38222-0e87-4f60-861a-3a20ef3dc6f8", "babb9e2b-81fe-446e-9b48-c2fe6fc972f4", "dab2f615-2a70-4af4-9c2e-5f815e2540e7", "748d475c-8653-4877-837a-ee4c9fe31737", "4b324c72-17f3-4951-b7f7-f917c7b1530d"]}	\N	\N	0	\N	2026-10-14 16:56:02.835872+00	2026-10-14 16:56:02.144225+00	2026-10-14 16:56:02.839854+00	FNE	B2B	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	\N	c495edf3-35b9-46fc-8adc-ad4a1e14e1e0	[{"order_item_id": "38b38222-0e87-4f60-861a-3a20ef3dc6f8", "fne_item_id": "e07d0dfa-9f94-4b85-83f6-9be415b8ac3a", "quantity": 1}, {"order_item_id": "babb9e2b-81fe-446e-9b48-c2fe6fc972f4", "fne_item_id": "62b7b8ff-f900-458c-ba5e-d20ac3c7b858", "quantity": 1}, {"order_item_id": "dab2f615-2a70-4af4-9c2e-5f815e2540e7", "fne_item_id": "6747df31-e0c9-4af2-af23-5095d8079640", "quantity": 1}, {"order_item_id": "748d475c-8653-4877-837a-ee4c9fe31737", "fne_item_id": "640b6c65-bf93-413d-9423-21cad24d9df6", "quantity": 1}, {"order_item_id": "4b324c72-17f3-4951-b7f7-f917c7b1530d", "fne_item_id": "d8e8f12f-270b-423c-b499-d6974282e9de", "quantity": 1}]	9500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000014	http://54.247.95.108/fr/verification/01a13b57-a79f-7223-9a06-c77057ca4d80	{"ncc": "1304777N", "reference": "1304777N26000000014", "token": "http://54.247.95.108/fr/verification/01a13b57-a79f-7223-9a06-c77057ca4d80", "warning": false, "balance_funds": 120220, "invoice": {"id": "c495edf3-35b9-46fc-8adc-ad4a1e14e1e0", "parentId": null, "parentReference": null, "token": "01a13b57-a79f-7223-9a06-c77057ca4d80", "reference": "1304777N26000000014", "type": "invoice", "subtype": "normal", "date": "2026-10-14T16:56:02.650Z", "paymentMethod": "cash", "amount": 9500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 9500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 9500, "totalCustomTaxes": 0, "totalDue": 9500, "clientNcc": "1254632A", "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": "", "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS foncier", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z", "items": [{"id": "e07d0dfa-9f94-4b85-83f6-9be415b8ac3a", "quantity": 1, "reference": "SYL-040", "description": "Tchep + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z", "taxes": [{"invoiceItemId": "e07d0dfa-9f94-4b85-83f6-9be415b8ac3a", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z"}], "customTaxes": [], "invoiceId": "c495edf3-35b9-46fc-8adc-ad4a1e14e1e0", "parentId": null, "discount": null}, {"id": "62b7b8ff-f900-458c-ba5e-d20ac3c7b858", "quantity": 1, "reference": "SYL-034", "description": "Salade Panach\\u00e9e + Sosso", "amount": 4000, "measurementUnit": "U", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z", "taxes": [{"invoiceItemId": "62b7b8ff-f900-458c-ba5e-d20ac3c7b858", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z"}], "customTaxes": [], "invoiceId": "c495edf3-35b9-46fc-8adc-ad4a1e14e1e0", "parentId": null, "discount": null}, {"id": "6747df31-e0c9-4af2-af23-5095d8079640", "quantity": 1, "reference": "SYL-077", "description": "Salade de fruits", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z", "taxes": [{"invoiceItemId": "6747df31-e0c9-4af2-af23-5095d8079640", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z"}], "customTaxes": [], "invoiceId": "c495edf3-35b9-46fc-8adc-ad4a1e14e1e0", "parentId": null, "discount": null}, {"id": "640b6c65-bf93-413d-9423-21cad24d9df6", "quantity": 1, "reference": "SYL-079", "description": "Bissap", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z", "taxes": [{"invoiceItemId": "640b6c65-bf93-413d-9423-21cad24d9df6", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z"}], "customTaxes": [], "invoiceId": "c495edf3-35b9-46fc-8adc-ad4a1e14e1e0", "parentId": null, "discount": null}, {"id": "d8e8f12f-270b-423c-b499-d6974282e9de", "quantity": 1, "reference": "SYL-078", "description": "Passion", "amount": 1000, "measurementUnit": "U", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z", "taxes": [{"invoiceItemId": "d8e8f12f-270b-423c-b499-d6974282e9de", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-14T16:56:02.650Z", "updatedAt": "2026-10-14T16:56:02.650Z"}], "customTaxes": [], "invoiceId": "c495edf3-35b9-46fc-8adc-ad4a1e14e1e0", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
18219b2f-b701-4d12-95c7-74e14fd684fb	9a9daf47-c991-4852-b474-f2d9c12f44ec	a6e273be-5851-421a-96f2-a5b56ee678d1	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Couscous + Poulet", "quantity": 1, "amount": 2500, "reference": "SYL-029", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Couscous + Poisson", "quantity": 1, "amount": 3000, "reference": "SYL-030", "measurementUnit": "U"}], "clientNcc": "1254632A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["cce56a6a-7d85-4538-bbb9-ff25c3a579f2", "33a25eb6-f42f-43d3-b1b8-c3da96afdb1a"]}	\N	\N	0	\N	2026-10-16 09:55:46.477791+00	2026-10-16 09:55:45.8922+00	2026-10-16 09:55:46.483943+00	FNE	B2B	0e8d76cb-c7be-43a9-9975-18ecfb230858	\N	02a8bc35-9f61-42d9-b94a-754a17d931ed	[{"order_item_id": "cce56a6a-7d85-4538-bbb9-ff25c3a579f2", "fne_item_id": "f86c728f-947e-4df3-9b7a-cf3379113464", "quantity": 1}, {"order_item_id": "33a25eb6-f42f-43d3-b1b8-c3da96afdb1a", "fne_item_id": "406e14d3-2601-4919-9fa6-aa67efe13a38", "quantity": 1}]	5500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000015	http://54.247.95.108/fr/verification/01a14423-9a31-7223-9a43-ded6f760e4b2	{"ncc": "1304777N", "reference": "1304777N26000000015", "token": "http://54.247.95.108/fr/verification/01a14423-9a31-7223-9a43-ded6f760e4b2", "warning": false, "balance_funds": 120200, "invoice": {"id": "02a8bc35-9f61-42d9-b94a-754a17d931ed", "parentId": null, "parentReference": null, "token": "01a14423-9a31-7223-9a43-ded6f760e4b2", "reference": "1304777N26000000015", "type": "invoice", "subtype": "normal", "date": "2026-10-16T09:55:46.297Z", "paymentMethod": "cash", "amount": 5500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 5500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 5500, "totalCustomTaxes": 0, "totalDue": 5500, "clientNcc": "1254632A", "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": "", "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS foncier", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-16T09:55:46.297Z", "updatedAt": "2026-10-16T09:55:46.297Z", "items": [{"id": "f86c728f-947e-4df3-9b7a-cf3379113464", "quantity": 1, "reference": "SYL-029", "description": "Couscous + Poulet", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-16T09:55:46.297Z", "updatedAt": "2026-10-16T09:55:46.297Z", "taxes": [{"invoiceItemId": "f86c728f-947e-4df3-9b7a-cf3379113464", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-16T09:55:46.297Z", "updatedAt": "2026-10-16T09:55:46.297Z"}], "customTaxes": [], "invoiceId": "02a8bc35-9f61-42d9-b94a-754a17d931ed", "parentId": null, "discount": null}, {"id": "406e14d3-2601-4919-9fa6-aa67efe13a38", "quantity": 1, "reference": "SYL-030", "description": "Couscous + Poisson", "amount": 3000, "measurementUnit": "U", "createdAt": "2026-10-16T09:55:46.297Z", "updatedAt": "2026-10-16T09:55:46.297Z", "taxes": [{"invoiceItemId": "406e14d3-2601-4919-9fa6-aa67efe13a38", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-16T09:55:46.297Z", "updatedAt": "2026-10-16T09:55:46.297Z"}], "customTaxes": [], "invoiceId": "02a8bc35-9f61-42d9-b94a-754a17d931ed", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
a5dcb845-5276-44ac-926e-eee1be0cf785	a898bc47-55b9-4ec3-a2e7-19e82a3d0552	a6e273be-5851-421a-96f2-a5b56ee678d1	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Igname bouillie + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-049", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Atti\\u00e9k\\u00e9 + Sosso", "quantity": 1, "amount": 4000, "reference": "SYL-062", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Igname bouillie + Sosso", "quantity": 1, "amount": 4000, "reference": "SYL-047", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Tamarin", "quantity": 4, "amount": 500, "reference": "SYL-080", "measurementUnit": "U"}], "clientNcc": "1254632A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["1cae931d-443b-4fe6-8912-9b6b6b2b2448", "51503f33-18b5-4c32-b1bc-d3b199f20aaf", "de0ced94-da04-4435-8d64-c152c6c51501", "d6ab7a35-644f-43bc-8dbf-22e54c560183"]}	\N	\N	0	\N	2026-10-19 14:39:11.877364+00	2026-10-19 14:39:11.098905+00	2026-10-19 14:39:11.881475+00	FNE	B2B	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	\N	c2aec99e-81d5-4882-94c6-79e2f0be308d	[{"order_item_id": "1cae931d-443b-4fe6-8912-9b6b6b2b2448", "fne_item_id": "d5a96ac3-9bd5-4be5-97fd-17a29ec136a8", "quantity": 1}, {"order_item_id": "51503f33-18b5-4c32-b1bc-d3b199f20aaf", "fne_item_id": "5c4b4b24-b819-4755-94d4-caafb788c10b", "quantity": 1}, {"order_item_id": "de0ced94-da04-4435-8d64-c152c6c51501", "fne_item_id": "1193b09a-7db4-4428-b9ff-cb83b03087c3", "quantity": 1}, {"order_item_id": "d6ab7a35-644f-43bc-8dbf-22e54c560183", "fne_item_id": "906fd8bd-05cc-4384-b817-b464f5df9080", "quantity": 4}]	13500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000017	http://54.247.95.108/fr/verification/01a1549a-2944-7223-9a60-57d96390c3b0	{"ncc": "1304777N", "reference": "1304777N26000000017", "token": "http://54.247.95.108/fr/verification/01a1549a-2944-7223-9a60-57d96390c3b0", "warning": false, "balance_funds": 120160, "invoice": {"id": "c2aec99e-81d5-4882-94c6-79e2f0be308d", "parentId": null, "parentReference": null, "token": "01a1549a-2944-7223-9a60-57d96390c3b0", "reference": "1304777N26000000017", "type": "invoice", "subtype": "normal", "date": "2026-10-19T14:39:11.623Z", "paymentMethod": "cash", "amount": 13500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 13500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 13500, "totalCustomTaxes": 0, "totalDue": 13500, "clientNcc": "1254632A", "clientCompanyName": "CONFEDERATION GENERALE DES ENTREPRISES", "clientPhone": "0767639874", "clientEmail": "main.9235@gmail.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": "", "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS foncier", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z", "items": [{"id": "d5a96ac3-9bd5-4be5-97fd-17a29ec136a8", "quantity": 1, "reference": "SYL-049", "description": "Igname bouillie + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z", "taxes": [{"invoiceItemId": "d5a96ac3-9bd5-4be5-97fd-17a29ec136a8", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z"}], "customTaxes": [], "invoiceId": "c2aec99e-81d5-4882-94c6-79e2f0be308d", "parentId": null, "discount": null}, {"id": "5c4b4b24-b819-4755-94d4-caafb788c10b", "quantity": 1, "reference": "SYL-062", "description": "Atti\\u00e9k\\u00e9 + Sosso", "amount": 4000, "measurementUnit": "U", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z", "taxes": [{"invoiceItemId": "5c4b4b24-b819-4755-94d4-caafb788c10b", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z"}], "customTaxes": [], "invoiceId": "c2aec99e-81d5-4882-94c6-79e2f0be308d", "parentId": null, "discount": null}, {"id": "1193b09a-7db4-4428-b9ff-cb83b03087c3", "quantity": 1, "reference": "SYL-047", "description": "Igname bouillie + Sosso", "amount": 4000, "measurementUnit": "U", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z", "taxes": [{"invoiceItemId": "1193b09a-7db4-4428-b9ff-cb83b03087c3", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z"}], "customTaxes": [], "invoiceId": "c2aec99e-81d5-4882-94c6-79e2f0be308d", "parentId": null, "discount": null}, {"id": "906fd8bd-05cc-4384-b817-b464f5df9080", "quantity": 4, "reference": "SYL-080", "description": "Tamarin", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z", "taxes": [{"invoiceItemId": "906fd8bd-05cc-4384-b817-b464f5df9080", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:39:11.623Z", "updatedAt": "2026-10-19T14:39:11.623Z"}], "customTaxes": [], "invoiceId": "c2aec99e-81d5-4882-94c6-79e2f0be308d", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
bbf6f146-2e7d-4c1a-92ae-f4c28b58e32b	e7997130-0ca2-4611-9a0f-547906350cfc	c10971e6-af3a-444f-806d-419be5fc06c8	FNE	CERTIFIED	\N	\N	\N	{"request": {"invoiceType": "sale", "paymentMethod": "cash", "template": "B2B", "isRne": false, "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "pointOfSale": "CAISSE-1", "establishment": "RESTAURANT CHEZ SYLLA PLUS", "foreignCurrency": "", "foreignCurrencyRate": 0, "items": [{"taxes": ["TVAD"], "description": "Kabato Lafri + Tripe", "quantity": 1, "amount": 2500, "reference": "SYL-003", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade Panach\\u00e9e + Sosso", "quantity": 1, "amount": 4000, "reference": "SYL-034", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "quantity": 1, "amount": 5000, "reference": "SYL-035", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Igname bouillie + Poisson brais\\u00e9", "quantity": 1, "amount": 5000, "reference": "SYL-048", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Igname frite + Mouton", "quantity": 1, "amount": 3500, "reference": "SYL-054", "measurementUnit": "U"}, {"taxes": ["TVAD"], "description": "Salade de fruits", "quantity": 1, "amount": 500, "reference": "SYL-077", "measurementUnit": "U"}], "clientNcc": "9506466A", "clientSellerName": "Digui Thio"}, "payment_method": "CASH", "order_item_ids": ["16f74585-dba3-45e7-9e07-447b4a0fda11", "2f76b8fc-a269-4c37-ab2f-1241d47303dd", "aa42d526-b039-486f-8474-f821cd4cb4f8", "6417888b-7b85-4cba-a757-f11e671b4b48", "fe6387e1-2fbe-4c67-8b09-3abed1548a19", "8e089f05-4650-4ecf-bb28-bf72020f998b"]}	\N	\N	0	\N	2026-10-19 14:41:30.31315+00	2026-10-19 14:41:29.645909+00	2026-10-19 14:41:30.315381+00	FNE	B2B	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	\N	f1f4ac63-4cf9-45f9-9745-f1e401984994	[{"order_item_id": "16f74585-dba3-45e7-9e07-447b4a0fda11", "fne_item_id": "47d1508c-5f7a-4044-bae4-bea970b894aa", "quantity": 1}, {"order_item_id": "2f76b8fc-a269-4c37-ab2f-1241d47303dd", "fne_item_id": "f840e71b-d290-4c9e-b51b-db220c24bab5", "quantity": 1}, {"order_item_id": "aa42d526-b039-486f-8474-f821cd4cb4f8", "fne_item_id": "f7ced62f-a167-4bf8-963f-782b88ac764d", "quantity": 1}, {"order_item_id": "6417888b-7b85-4cba-a757-f11e671b4b48", "fne_item_id": "9339bd61-e27e-4dca-82c4-1353d0c6b7a4", "quantity": 1}, {"order_item_id": "fe6387e1-2fbe-4c67-8b09-3abed1548a19", "fne_item_id": "0cbc67f5-b495-45fd-91f3-9922591a9d12", "quantity": 1}, {"order_item_id": "8e089f05-4650-4ecf-bb28-bf72020f998b", "fne_item_id": "38fd4f95-d5b4-4c4c-8ec1-5e2051c6c081", "quantity": 1}]	20500	\N	f	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1304777N26000000018	http://54.247.95.108/fr/verification/01a1549c-464f-7eed-8d0c-0c720b610b4d	{"ncc": "1304777N", "reference": "1304777N26000000018", "token": "http://54.247.95.108/fr/verification/01a1549c-464f-7eed-8d0c-0c720b610b4d", "warning": false, "balance_funds": 120140, "invoice": {"id": "f1f4ac63-4cf9-45f9-9745-f1e401984994", "parentId": null, "parentReference": null, "token": "01a1549c-464f-7eed-8d0c-0c720b610b4d", "reference": "1304777N26000000018", "type": "invoice", "subtype": "normal", "date": "2026-10-19T14:41:30.129Z", "paymentMethod": "cash", "amount": 20500, "vatAmount": 0, "fiscalStamp": 0, "discount": null, "totalBeforeTaxes": 20500, "totalDiscounted": 0, "totalTaxes": 0, "totalAfterTaxes": 20500, "totalCustomTaxes": 0, "totalDue": 20500, "clientNcc": "9506466A", "clientCompanyName": "AGL GRP", "clientPhone": "0123546987", "clientEmail": "agl.grp@live.com", "clientTerminal": null, "clientMerchantName": null, "clientRccm": null, "clientSellerName": "Digui Thio", "clientEstablishment": "RESTAURANT CHEZ SYLLA PLUS", "clientPointOfSale": "CAISSE-1", "clientTaxRegime": "RS employeur", "status": "paid", "template": "B2B", "description": null, "footer": null, "commercialMessage": null, "foreignCurrency": "", "foreignCurrencyRate": 0, "isRne": false, "rne": null, "source": "api", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z", "items": [{"id": "47d1508c-5f7a-4044-bae4-bea970b894aa", "quantity": 1, "reference": "SYL-003", "description": "Kabato Lafri + Tripe", "amount": 2500, "measurementUnit": "U", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z", "taxes": [{"invoiceItemId": "47d1508c-5f7a-4044-bae4-bea970b894aa", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z"}], "customTaxes": [], "invoiceId": "f1f4ac63-4cf9-45f9-9745-f1e401984994", "parentId": null, "discount": null}, {"id": "f840e71b-d290-4c9e-b51b-db220c24bab5", "quantity": 1, "reference": "SYL-034", "description": "Salade Panach\\u00e9e + Sosso", "amount": 4000, "measurementUnit": "U", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z", "taxes": [{"invoiceItemId": "f840e71b-d290-4c9e-b51b-db220c24bab5", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z"}], "customTaxes": [], "invoiceId": "f1f4ac63-4cf9-45f9-9745-f1e401984994", "parentId": null, "discount": null}, {"id": "f7ced62f-a167-4bf8-963f-782b88ac764d", "quantity": 1, "reference": "SYL-035", "description": "Salade Panach\\u00e9e + Poisson brais\\u00e9", "amount": 5000, "measurementUnit": "U", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z", "taxes": [{"invoiceItemId": "f7ced62f-a167-4bf8-963f-782b88ac764d", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z"}], "customTaxes": [], "invoiceId": "f1f4ac63-4cf9-45f9-9745-f1e401984994", "parentId": null, "discount": null}, {"id": "9339bd61-e27e-4dca-82c4-1353d0c6b7a4", "quantity": 1, "reference": "SYL-048", "description": "Igname bouillie + Poisson brais\\u00e9", "amount": 5000, "measurementUnit": "U", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z", "taxes": [{"invoiceItemId": "9339bd61-e27e-4dca-82c4-1353d0c6b7a4", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z"}], "customTaxes": [], "invoiceId": "f1f4ac63-4cf9-45f9-9745-f1e401984994", "parentId": null, "discount": null}, {"id": "0cbc67f5-b495-45fd-91f3-9922591a9d12", "quantity": 1, "reference": "SYL-054", "description": "Igname frite + Mouton", "amount": 3500, "measurementUnit": "U", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z", "taxes": [{"invoiceItemId": "0cbc67f5-b495-45fd-91f3-9922591a9d12", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z"}], "customTaxes": [], "invoiceId": "f1f4ac63-4cf9-45f9-9745-f1e401984994", "parentId": null, "discount": null}, {"id": "38fd4f95-d5b4-4c4c-8ec1-5e2051c6c081", "quantity": 1, "reference": "SYL-077", "description": "Salade de fruits", "amount": 500, "measurementUnit": "U", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z", "taxes": [{"invoiceItemId": "38fd4f95-d5b4-4c4c-8ec1-5e2051c6c081", "vatRateId": "a67f826b-063e-4b0e-8fcc-a37c81c5e792", "amount": 0, "name": "TVA exo.l\\u00e9g - Pas de TVA sur HT 00,00% - D (TEE, TCE, Microentreprise)", "shortName": "TVAD", "createdAt": "2026-10-19T14:41:30.129Z", "updatedAt": "2026-10-19T14:41:30.129Z"}], "customTaxes": [], "invoiceId": "f1f4ac63-4cf9-45f9-9745-f1e401984994", "parentId": null, "discount": null}], "customTaxes": []}}	1	\N	\N
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
pay-b61f47d3-6a41-4cbb-bc0c-84fcc09036f5-1791286212581-lrcxbj9	/orders/b61f47d3-6a41-4cbb-bc0c-84fcc09036f5/payments		201	{"payment": {"id": "b916d44e-3cc3-4656-99e0-ea6086f708a9", "order_id": "b61f47d3-6a41-4cbb-bc0c-84fcc09036f5", "method": "CASH", "amount_xof": 13500, "tendered_xof": 14000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-06T11:30:12.642293+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "2beadc3a-569c-4edb-8de3-1390de02a9f4", "fne_status": "CERTIFIED", "warnings": []}	2026-10-06 11:30:14.534188+00	2026-10-06 11:30:14.534202+00
pay-4dca0121-6712-4315-8098-c7cb86dad49d-1791287629317-ikuydxj	/orders/4dca0121-6712-4315-8098-c7cb86dad49d/payments		201	{"payment": {"id": "a1634473-271f-443f-a6b0-30130d12effa", "order_id": "4dca0121-6712-4315-8098-c7cb86dad49d", "method": "CASH", "amount_xof": 7000, "tendered_xof": 10000, "change_xof": 3000, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-06T11:53:49.359877+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 3000, "drawer_opened": true, "print_job_id": "cd6d740f-1bdb-4564-babe-75a33aa65ca6", "fne_status": null, "warnings": []}	2026-10-06 11:53:49.434511+00	2026-10-06 11:53:49.434523+00
pay-c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd-1791296925355-881c8fs	/orders/c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd/payments		201	{"payment": {"id": "8b700a71-4528-4588-9a29-7d4ba886e8ed", "order_id": "c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd", "method": "MOBILE_MONEY", "amount_xof": 15500, "tendered_xof": 15500, "change_xof": 0, "provider": "WAVE", "reference": null, "status": "CAPTURED", "created_at": "2026-10-06T14:28:45.392271+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "fa9540be-233f-48d4-81fe-bfe91a9131e1", "fne_status": null, "warnings": []}	2026-10-06 14:28:45.467957+00	2026-10-06 14:28:45.467968+00
pay-1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2-1791297599978-esvgr14	/orders/1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2/payments		201	{"payment": {"id": "dee46df9-b970-409f-bcea-1555176e82f4", "order_id": "1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2", "method": "CASH", "amount_xof": 17500, "tendered_xof": 17500, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-06T14:40:00.023553+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "872cd0e1-9d6d-49b5-91ef-6f868593e3c1", "fne_status": "CERTIFIED", "warnings": []}	2026-10-06 14:40:00.97677+00	2026-10-06 14:40:00.976783+00
pay-64526137-92a1-418d-9d03-6393030d1f1f-1791299337740-nkthgc9	/orders/64526137-92a1-418d-9d03-6393030d1f1f/payments		201	{"payment": {"id": "fccf036d-3005-4f99-870f-c6680aaf2a31", "order_id": "64526137-92a1-418d-9d03-6393030d1f1f", "method": "CASH", "amount_xof": 9500, "tendered_xof": 10000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-06T15:08:57.816120+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "096f5ca7-3e34-461f-9fb2-b93725d4fa0a", "fne_status": null, "warnings": []}	2026-10-06 15:08:58.06844+00	2026-10-06 15:08:58.06845+00
pay-b3149ccf-0f04-4a5c-8ff9-5aad99d0a137-1791299400930-2zffk0a	/orders/b3149ccf-0f04-4a5c-8ff9-5aad99d0a137/payments		201	{"payment": {"id": "761b7ef5-f574-43d1-9038-bc5b0eeadcb4", "order_id": "b3149ccf-0f04-4a5c-8ff9-5aad99d0a137", "method": "CASH", "amount_xof": 14500, "tendered_xof": 15000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-06T15:10:00.976610+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "db289b8c-5158-43c2-84ac-9dd82fe88e7c", "fne_status": null, "warnings": []}	2026-10-06 15:10:01.324457+00	2026-10-06 15:10:01.324468+00
pay-0518ad5e-03a6-4c5a-9636-b9d33da54b4d-1791300981640-sgaiukk	/orders/0518ad5e-03a6-4c5a-9636-b9d33da54b4d/payments		201	{"payment": {"id": "544d8200-4a3d-43c1-80c1-45d37ea95f5a", "order_id": "0518ad5e-03a6-4c5a-9636-b9d33da54b4d", "method": "CASH", "amount_xof": 15500, "tendered_xof": 16000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-06T15:36:21.696793+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "c810324e-24e9-4f8f-8513-2453cc52f1dd", "fne_status": "CERTIFIED", "warnings": []}	2026-10-06 15:36:23.079994+00	2026-10-06 15:36:23.080003+00
pay-5c853bf0-1866-4f88-a27d-f1fb5caca8f6-1791301085428-xreh3d5	/orders/5c853bf0-1866-4f88-a27d-f1fb5caca8f6/payments		201	{"payment": {"id": "2abfb1c6-924f-4ca4-b42a-828add61ceff", "order_id": "5c853bf0-1866-4f88-a27d-f1fb5caca8f6", "method": "CASH", "amount_xof": 14500, "tendered_xof": 15000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-06T15:38:05.460328+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "a82af4f1-6dd6-43be-9cc7-53177624e7ab", "fne_status": null, "warnings": []}	2026-10-06 15:38:05.553004+00	2026-10-06 15:38:05.553014+00
pay-c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a-1791456468769-8dgt827	/orders/c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a/payments		201	{"payment": {"id": "9053909f-a781-4609-9174-1e986810c412", "order_id": "c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a", "method": "CASH", "amount_xof": 8000, "tendered_xof": 8000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-08T10:47:48.818684+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "080ddf17-ec1e-492d-9247-79083381551a", "fne_status": null, "warnings": []}	2026-10-08 10:47:49.105294+00	2026-10-08 10:47:49.105305+00
pay-21a1947c-5da6-4a14-ae3f-a931b866bb53-1791458180563-su99j77	/orders/21a1947c-5da6-4a14-ae3f-a931b866bb53/payments		201	{"payment": {"id": "b86016a3-57a4-4d79-8a82-92349aad5825", "order_id": "21a1947c-5da6-4a14-ae3f-a931b866bb53", "method": "CASH", "amount_xof": 8000, "tendered_xof": 8000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-08T11:16:20.634467+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "2d30f63f-5f0b-4917-8114-839de4fe2821", "fne_status": "CERTIFIED", "warnings": []}	2026-10-08 11:16:21.956218+00	2026-10-08 11:16:21.95623+00
pay-db5be098-d0bf-42f8-91e8-9a1ecd858825-1791470637450-pecq95p	/orders/db5be098-d0bf-42f8-91e8-9a1ecd858825/payments		201	{"payment": {"id": "91b83a0e-d8d4-48ee-9e5b-6769b4e07e39", "order_id": "db5be098-d0bf-42f8-91e8-9a1ecd858825", "method": "CASH", "amount_xof": 9000, "tendered_xof": 10000, "change_xof": 1000, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-08T14:43:57.520620+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 1000, "drawer_opened": true, "print_job_id": "d1cffe21-0966-4057-9a98-fb6e17ea3226", "fne_status": null, "warnings": []}	2026-10-08 14:43:57.835088+00	2026-10-08 14:43:57.835097+00
pay-1ae79c99-2c11-40f4-9b4e-6948b5256aed-1791470771894-3zkola6	/orders/1ae79c99-2c11-40f4-9b4e-6948b5256aed/payments		201	{"payment": {"id": "6a6e1813-0825-4c8c-8a7d-06bbf91bdbea", "order_id": "1ae79c99-2c11-40f4-9b4e-6948b5256aed", "method": "CASH", "amount_xof": 17500, "tendered_xof": 20000, "change_xof": 2500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-08T14:46:11.928568+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 2500, "drawer_opened": true, "print_job_id": "54a306d4-2804-4003-b968-15e5844dfb80", "fne_status": "CERTIFIED", "warnings": []}	2026-10-08 14:46:13.289457+00	2026-10-08 14:46:13.289466+00
pay-9a9fc6d5-9fb0-4031-929e-50035995d1db-1791471960257-babmt5f	/orders/9a9fc6d5-9fb0-4031-929e-50035995d1db/payments		201	{"payment": {"id": "6251cc2f-2a4b-41ad-8fb5-74ada8579abc", "order_id": "9a9fc6d5-9fb0-4031-929e-50035995d1db", "method": "MOBILE_MONEY", "amount_xof": 3500, "tendered_xof": 3500, "change_xof": 0, "provider": "ORANGE_MONEY", "reference": null, "status": "CAPTURED", "created_at": "2026-10-08T15:06:00.305398+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "3723b6b7-e724-4272-a623-b8c41734b783", "fne_status": null, "warnings": []}	2026-10-08 15:06:00.525446+00	2026-10-08 15:06:00.525456+00
pay-867b6c58-13d3-4af8-8f2e-094ae7f69f2c-1791472000933-hg68foq	/orders/867b6c58-13d3-4af8-8f2e-094ae7f69f2c/payments		201	{"payment": {"id": "0336184a-b88c-463d-9ea9-8e7cfae6fce9", "order_id": "867b6c58-13d3-4af8-8f2e-094ae7f69f2c", "method": "MOBILE_MONEY", "amount_xof": 2500, "tendered_xof": 2500, "change_xof": 0, "provider": "MTN_MOMO", "reference": null, "status": "CAPTURED", "created_at": "2026-10-08T15:06:40.974457+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "29430dcb-10d6-4463-b6e4-df8288ed5055", "fne_status": null, "warnings": []}	2026-10-08 15:06:41.049606+00	2026-10-08 15:06:41.049625+00
pay-076109cb-177f-408e-b8d2-1a2ca7c82b9b-1791472038207-ln1qvtg	/orders/076109cb-177f-408e-b8d2-1a2ca7c82b9b/payments		201	{"payment": {"id": "dfb0d182-a56c-46e8-860a-d52410f695c6", "order_id": "076109cb-177f-408e-b8d2-1a2ca7c82b9b", "method": "MOBILE_MONEY", "amount_xof": 17000, "tendered_xof": 17000, "change_xof": 0, "provider": "WAVE", "reference": null, "status": "CAPTURED", "created_at": "2026-10-08T15:07:18.250195+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "57e8ea24-0036-4fab-8bf4-2dbaee87ee13", "fne_status": null, "warnings": []}	2026-10-08 15:07:18.38386+00	2026-10-08 15:07:18.383869+00
pay-e6ff5588-1a97-409f-b651-8dcd1ec5135b-1791472424248-udc53x1	/orders/e6ff5588-1a97-409f-b651-8dcd1ec5135b/payments		201	{"payment": {"id": "f87360b3-2919-45b5-9c8f-f0d21ba4c4e1", "order_id": "e6ff5588-1a97-409f-b651-8dcd1ec5135b", "method": "CASH", "amount_xof": 11500, "tendered_xof": 12000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-08T15:13:44.293073+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "9bb7afd2-feff-4b55-8493-dd6e2f4ca694", "fne_status": "CERTIFIED", "warnings": []}	2026-10-08 15:13:45.246188+00	2026-10-08 15:13:45.246199+00
pay-c7b4ce76-37d6-4963-83b6-5da7c270aa02-1791894040647-4ttw4ev	/orders/c7b4ce76-37d6-4963-83b6-5da7c270aa02/payments		201	{"payment": {"id": "556b1b9f-3bad-47d0-a487-0879ec2aae3f", "order_id": "c7b4ce76-37d6-4963-83b6-5da7c270aa02", "method": "MOBILE_MONEY", "amount_xof": 10000, "tendered_xof": 10000, "change_xof": 0, "provider": "WAVE", "reference": null, "status": "CAPTURED", "created_at": "2026-10-13T12:20:40.722673+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "776bea63-e13a-44b7-9776-614e16d8c8d0", "fne_status": "CERTIFIED", "warnings": []}	2026-10-13 12:20:42.128274+00	2026-10-13 12:20:42.128283+00
pay-39bd2f25-6504-419b-b010-af921b9e733a-1791894145110-7davtno	/orders/39bd2f25-6504-419b-b010-af921b9e733a/payments		201	{"payment": {"id": "141a3d65-75fb-4489-9749-d7fcac22031b", "order_id": "39bd2f25-6504-419b-b010-af921b9e733a", "method": "MOBILE_MONEY", "amount_xof": 7500, "tendered_xof": 7500, "change_xof": 0, "provider": "ORANGE_MONEY", "reference": null, "status": "CAPTURED", "created_at": "2026-10-13T12:22:25.149974+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "99d1ca98-dbbf-4eb0-80ea-68ca40bf004c", "fne_status": null, "warnings": []}	2026-10-13 12:22:25.24707+00	2026-10-13 12:22:25.247084+00
pay-70e4726f-ac39-499c-9e84-97f3ccd8b1d1-1791894227969-umwg3x2	/orders/70e4726f-ac39-499c-9e84-97f3ccd8b1d1/payments		201	{"payment": {"id": "b53715e2-f60d-4478-8013-11270c7e0732", "order_id": "70e4726f-ac39-499c-9e84-97f3ccd8b1d1", "method": "CASH", "amount_xof": 14000, "tendered_xof": 15000, "change_xof": 1000, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-13T12:23:48.010176+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 1000, "drawer_opened": true, "print_job_id": "51c9b789-6607-4c41-a8d8-369f5f10fc3c", "fne_status": null, "warnings": []}	2026-10-13 12:23:48.112481+00	2026-10-13 12:23:48.112492+00
pay-ea858ea2-6771-49c3-b09b-253f7cadb4e4-1791903275348-20d2yih	/orders/ea858ea2-6771-49c3-b09b-253f7cadb4e4/payments		201	{"payment": {"id": "6f69dfb8-77f9-40ea-9405-ed3cfb579320", "order_id": "ea858ea2-6771-49c3-b09b-253f7cadb4e4", "method": "MOBILE_MONEY", "amount_xof": 9000, "tendered_xof": 9000, "change_xof": 0, "provider": "MTN_MOMO", "reference": null, "status": "CAPTURED", "created_at": "2026-10-13T14:54:35.413387+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "4383751e-f30b-40d5-bdd4-5e9cfa53ed42", "fne_status": null, "warnings": []}	2026-10-13 14:54:35.986463+00	2026-10-13 14:54:35.986474+00
pay-e39da534-1326-47b7-a6e2-b3bdccfbd904-1791903361221-2zh6piw	/orders/e39da534-1326-47b7-a6e2-b3bdccfbd904/payments		201	{"payment": {"id": "88bb26c8-211a-450a-b8c3-372434e60909", "order_id": "e39da534-1326-47b7-a6e2-b3bdccfbd904", "method": "CASH", "amount_xof": 6000, "tendered_xof": 10000, "change_xof": 4000, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-13T14:56:01.257437+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 4000, "drawer_opened": true, "print_job_id": "ff2106c5-3ea5-4a62-9f4c-c0bf1d36fd6b", "fne_status": "CERTIFIED", "warnings": []}	2026-10-13 14:56:02.198524+00	2026-10-13 14:56:02.198535+00
pay-998f84b2-586b-47c9-98ce-bcd1becca088-1791991426872-fxyrrl8	/orders/998f84b2-586b-47c9-98ce-bcd1becca088/payments		201	{"payment": {"id": "cd22b82a-d706-43b3-81ef-8483095f121c", "order_id": "998f84b2-586b-47c9-98ce-bcd1becca088", "method": "CASH", "amount_xof": 13000, "tendered_xof": 13000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-14T15:23:46.949094+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "76431eb1-7cfd-43c3-95d8-76239ca73d90", "fne_status": "SUBMITTING", "warnings": []}	2026-10-14 15:23:51.296932+00	2026-10-14 15:23:51.296947+00
pay-ce2dd852-2947-4e23-b62e-4d8df1a69490-1791992130228-dhnlowo	/orders/ce2dd852-2947-4e23-b62e-4d8df1a69490/payments		201	{"payment": {"id": "5678587a-33a1-4145-b03c-900dc0e8b22f", "order_id": "ce2dd852-2947-4e23-b62e-4d8df1a69490", "method": "CASH", "amount_xof": 3500, "tendered_xof": 5000, "change_xof": 1500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-14T15:35:30.265095+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 1500, "drawer_opened": true, "print_job_id": "ec5eec2f-b77f-4468-9bb4-633dc26228f8", "fne_status": null, "warnings": []}	2026-10-14 15:35:30.367622+00	2026-10-14 15:35:30.367633+00
pay-4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8-1791996933460-age9bqn	/orders/4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8/payments		201	{"payment": {"id": "2d3f2a08-a6fd-4a0e-8890-e7e93a0fe81a", "order_id": "4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8", "method": "CASH", "amount_xof": 2500, "tendered_xof": 3000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-14T16:55:33.501692+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "5bbe85e2-24ce-4d3b-b829-7b543a9a1068", "fne_status": null, "warnings": []}	2026-10-14 16:55:33.595106+00	2026-10-14 16:55:33.595123+00
pay-1d99a39f-4263-4b0f-b6dd-6544080aab4a-1791996962009-28erpo8	/orders/1d99a39f-4263-4b0f-b6dd-6544080aab4a/payments		201	{"payment": {"id": "0c5afc42-12f1-43c5-85cd-eb07feb63e08", "order_id": "1d99a39f-4263-4b0f-b6dd-6544080aab4a", "method": "CASH", "amount_xof": 9500, "tendered_xof": 10000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-14T16:56:02.047517+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "02a3a58d-7d09-4f37-8840-495f3bab472d", "fne_status": "CERTIFIED", "warnings": []}	2026-10-14 16:56:02.881044+00	2026-10-14 16:56:02.881055+00
pay-f2fb511b-1bdd-4b34-8174-1b6c7ab582b0-1792065107623-uk71sg3	/orders/f2fb511b-1bdd-4b34-8174-1b6c7ab582b0/payments		201	{"payment": {"id": "d487a3b5-bf6b-440d-96bb-ffaa31fc9b68", "order_id": "f2fb511b-1bdd-4b34-8174-1b6c7ab582b0", "method": "CASH", "amount_xof": 18500, "tendered_xof": 20000, "change_xof": 1500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-15T11:51:47.715684+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 1500, "drawer_opened": true, "print_job_id": "b137a206-074a-4ffc-9ded-d7bed835154a", "fne_status": null, "warnings": []}	2026-10-15 11:51:48.087733+00	2026-10-15 11:51:48.087749+00
pay-ee578b03-ff99-40a0-9313-02085d248038-1792065167064-1k9nbr9	/orders/ee578b03-ff99-40a0-9313-02085d248038/payments		201	{"payment": {"id": "53738b3c-1ef5-4f0c-a620-f00af82e1bfe", "order_id": "ee578b03-ff99-40a0-9313-02085d248038", "method": "MOBILE_MONEY", "amount_xof": 11500, "tendered_xof": 11500, "change_xof": 0, "provider": "WAVE", "reference": null, "status": "CAPTURED", "created_at": "2026-10-15T11:52:47.099542+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "17496bc3-187a-48aa-a4af-bfbef01a4441", "fne_status": null, "warnings": []}	2026-10-15 11:52:47.183795+00	2026-10-15 11:52:47.183808+00
pay-04f24f74-7622-466b-b090-0f065946e004-1792066485256-ddgj3vn	/orders/04f24f74-7622-466b-b090-0f065946e004/payments		201	{"payment": {"id": "f1917d71-6db8-46ac-bb8b-5e7b32711e5d", "order_id": "04f24f74-7622-466b-b090-0f065946e004", "method": "CASH", "amount_xof": 13500, "tendered_xof": 15000, "change_xof": 1500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-15T12:14:45.300520+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 1500, "drawer_opened": true, "print_job_id": "1be447cb-0320-49e4-9d82-907ffef9c980", "fne_status": null, "warnings": []}	2026-10-15 12:14:45.781217+00	2026-10-15 12:14:45.781226+00
pay-68380b5e-667a-4c22-b3b3-a4b9e0674607-1792077123250-74ifjcr	/orders/68380b5e-667a-4c22-b3b3-a4b9e0674607/payments		201	{"payment": {"id": "bbe0106e-b4e8-4e46-8f4c-561066cecb13", "order_id": "68380b5e-667a-4c22-b3b3-a4b9e0674607", "method": "CASH", "amount_xof": 3000, "tendered_xof": 3000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-15T15:12:03.304665+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "b1f8b2bd-682d-41bf-b903-532a8169379e", "fne_status": null, "warnings": []}	2026-10-15 15:12:03.855838+00	2026-10-15 15:12:03.855859+00
pay-778a91c8-9cce-44e7-91b9-e5ff90fd0a23-1792082468839-gbpy8ao	/orders/778a91c8-9cce-44e7-91b9-e5ff90fd0a23/payments		201	{"payment": {"id": "666975d6-7915-4b61-a067-680e8cfbb971", "order_id": "778a91c8-9cce-44e7-91b9-e5ff90fd0a23", "method": "CASH", "amount_xof": 16000, "tendered_xof": 16000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-15T16:41:08.889838+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "24623428-f770-498e-9483-6a8ae4c881d4", "fne_status": null, "warnings": []}	2026-10-15 16:41:09.179981+00	2026-10-15 16:41:09.179989+00
pay-9a9daf47-c991-4852-b474-f2d9c12f44ec-1792144545626-gijvpiq	/orders/9a9daf47-c991-4852-b474-f2d9c12f44ec/payments		201	{"payment": {"id": "22202f24-9b04-4266-a096-020dc012083b", "order_id": "9a9daf47-c991-4852-b474-f2d9c12f44ec", "method": "CASH", "amount_xof": 5500, "tendered_xof": 5500, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-16T09:55:45.679913+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "6e57b71f-f69e-4646-baf8-b3a1ab2c49e7", "fne_status": "CERTIFIED", "warnings": []}	2026-10-16 09:55:46.759743+00	2026-10-16 09:55:46.759756+00
pay-722b3daf-c534-4a28-96a1-c7f866dcb6e4-1792144920215-bi0q1ra	/orders/722b3daf-c534-4a28-96a1-c7f866dcb6e4/payments		201	{"payment": {"id": "4f79df43-0c12-4d28-8497-1bb9122f5b5d", "order_id": "722b3daf-c534-4a28-96a1-c7f866dcb6e4", "method": "CASH", "amount_xof": 7500, "tendered_xof": 7500, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-16T10:02:00.270090+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "067166f3-b112-44ed-8bd9-4f840b7cb66d", "fne_status": "CERTIFIED", "warnings": []}	2026-10-16 10:02:01.055576+00	2026-10-16 10:02:01.055586+00
pay-e8a42cf0-5a2f-41e7-85db-4a8ba423084d-1792146356516-4p8d9kz	/orders/e8a42cf0-5a2f-41e7-85db-4a8ba423084d/payments		201	{"payment": {"id": "f1b90d2b-4330-4c41-9344-44c98e756582", "order_id": "e8a42cf0-5a2f-41e7-85db-4a8ba423084d", "method": "CASH", "amount_xof": 5500, "tendered_xof": 5500, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-16T10:25:56.582465+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "bdb3d023-f7eb-49f1-b0f3-f3b044a26b17", "fne_status": null, "warnings": []}	2026-10-16 10:25:56.875524+00	2026-10-16 10:25:56.875534+00
pay-3caa47f0-5560-456a-830e-e0e31694dc3d-1792146377558-xmpjjhn	/orders/3caa47f0-5560-456a-830e-e0e31694dc3d/payments		201	{"payment": {"id": "b33e307a-1901-436c-8e95-b2a2f02f2dc7", "order_id": "3caa47f0-5560-456a-830e-e0e31694dc3d", "method": "CASH", "amount_xof": 12500, "tendered_xof": 12500, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-16T10:26:17.600323+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "0062b664-5f00-497f-9520-8984743be713", "fne_status": null, "warnings": []}	2026-10-16 10:26:17.672821+00	2026-10-16 10:26:17.672831+00
pay-3f8f8dc6-11b6-4706-9a16-5033b227f0d1-1792419652286-7np1zjd	/orders/3f8f8dc6-11b6-4706-9a16-5033b227f0d1/payments		201	{"payment": {"id": "219650f5-63b9-4867-9c38-0f27414fcdc6", "order_id": "3f8f8dc6-11b6-4706-9a16-5033b227f0d1", "method": "CASH", "amount_xof": 7500, "tendered_xof": 8000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:20:52.363014+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "75b5415a-c717-4f37-969c-806eb25413ef", "fne_status": null, "warnings": []}	2026-10-19 14:20:52.821922+00	2026-10-19 14:20:52.821935+00
pay-41ec42f2-0c63-4e29-9fa8-c6b043ea9669-1792419759514-5yytel4	/orders/41ec42f2-0c63-4e29-9fa8-c6b043ea9669/payments		201	{"payment": {"id": "89fe7d08-379c-4a4c-8d64-e4bfd7c5bb0d", "order_id": "41ec42f2-0c63-4e29-9fa8-c6b043ea9669", "method": "CASH", "amount_xof": 15000, "tendered_xof": 20000, "change_xof": 5000, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:22:39.557676+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 5000, "drawer_opened": true, "print_job_id": "272eaf3f-5cc5-40cf-8e75-7cd17b568b97", "fne_status": null, "warnings": []}	2026-10-19 14:22:39.645308+00	2026-10-19 14:22:39.645319+00
pay-a898bc47-55b9-4ec3-a2e7-19e82a3d0552-1792420750971-484bz44	/orders/a898bc47-55b9-4ec3-a2e7-19e82a3d0552/payments		201	{"payment": {"id": "a6071376-6f80-47c5-b70e-1674bc6706e5", "order_id": "a898bc47-55b9-4ec3-a2e7-19e82a3d0552", "method": "CASH", "amount_xof": 13500, "tendered_xof": 15000, "change_xof": 1500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:39:11.009276+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 1500, "drawer_opened": true, "print_job_id": "71bdb4a2-929d-4649-aa16-62f5f05f0606", "fne_status": "CERTIFIED", "warnings": []}	2026-10-19 14:39:12.221449+00	2026-10-19 14:39:12.221461+00
pay-e7997130-0ca2-4611-9a0f-547906350cfc-1792420889552-j73kjfc	/orders/e7997130-0ca2-4611-9a0f-547906350cfc/payments		201	{"payment": {"id": "2114e5e1-2451-41df-9bc1-b25f7382c564", "order_id": "e7997130-0ca2-4611-9a0f-547906350cfc", "method": "CASH", "amount_xof": 20500, "tendered_xof": 21000, "change_xof": 500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:41:29.593625+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 500, "drawer_opened": true, "print_job_id": "b222e535-e7b1-4867-a13d-c365ff043ebb", "fne_status": "CERTIFIED", "warnings": []}	2026-10-19 14:41:30.404689+00	2026-10-19 14:41:30.404698+00
pay-8c1faad9-c719-4e21-bd8b-e3db15751754-1792420959163-8566tvt	/orders/8c1faad9-c719-4e21-bd8b-e3db15751754/payments		201	{"payment": {"id": "369550f7-dbb0-496d-b9ba-0e8b2c37b701", "order_id": "8c1faad9-c719-4e21-bd8b-e3db15751754", "method": "CASH", "amount_xof": 10000, "tendered_xof": 10000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:42:39.187591+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "19c99947-3d92-451a-bfa0-fa94573ebd7d", "fne_status": null, "warnings": []}	2026-10-19 14:42:39.232866+00	2026-10-19 14:42:39.232874+00
pay-dec8e488-1dc9-48fc-a597-47ca3a193e10-1792421049524-1bubjii	/orders/dec8e488-1dc9-48fc-a597-47ca3a193e10/payments		201	{"payment": {"id": "3bec01b1-2954-4bb5-bb9c-9cf95068b21f", "order_id": "dec8e488-1dc9-48fc-a597-47ca3a193e10", "method": "CASH", "amount_xof": 2000, "tendered_xof": 2000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:44:09.548816+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "160416a7-6958-4791-91e8-3ddd1aa8ecc8", "fne_status": null, "warnings": []}	2026-10-19 14:44:09.600815+00	2026-10-19 14:44:09.600825+00
pay-82620f6e-2b11-4bc8-b541-aac6644dc809-1792421066341-ulfq04m	/orders/82620f6e-2b11-4bc8-b541-aac6644dc809/payments		201	{"payment": {"id": "bd86f281-ceb4-46eb-a183-1f86bb0869ca", "order_id": "82620f6e-2b11-4bc8-b541-aac6644dc809", "method": "CASH", "amount_xof": 10000, "tendered_xof": 10000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:44:26.370580+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "8e0eb1dc-8339-438f-92b2-a1da623a23d4", "fne_status": null, "warnings": []}	2026-10-19 14:44:26.423819+00	2026-10-19 14:44:26.423831+00
pay-234ba969-bf26-4b05-88fa-6f0de2f6664d-1792421104387-y3aruz0	/orders/234ba969-bf26-4b05-88fa-6f0de2f6664d/payments		201	{"payment": {"id": "395a14da-f7b8-44e4-98fd-9f527159c498", "order_id": "234ba969-bf26-4b05-88fa-6f0de2f6664d", "method": "MOBILE_MONEY", "amount_xof": 11000, "tendered_xof": 11000, "change_xof": 0, "provider": "WAVE", "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:45:04.412247+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "3f8df834-38b9-4dd7-b632-07e047bef0db", "fne_status": null, "warnings": []}	2026-10-19 14:45:04.456962+00	2026-10-19 14:45:04.45697+00
pay-b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1-1792421132312-sp80j3e	/orders/b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1/payments		201	{"payment": {"id": "564d9fcf-ffbd-4e2c-a492-e3b046174f99", "order_id": "b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1", "method": "MOBILE_MONEY", "amount_xof": 20000, "tendered_xof": 20000, "change_xof": 0, "provider": "MTN_MOMO", "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:45:32.338375+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "c66f149b-b2fc-4874-91d9-b573948a640b", "fne_status": null, "warnings": []}	2026-10-19 14:45:32.379782+00	2026-10-19 14:45:32.379791+00
pay-6138d6a8-6f96-47ed-b093-baf0cfb04fa8-1792421172312-i93ipii	/orders/6138d6a8-6f96-47ed-b093-baf0cfb04fa8/payments		201	{"payment": {"id": "582db3ba-ce42-4d99-b3a6-914709af83b3", "order_id": "6138d6a8-6f96-47ed-b093-baf0cfb04fa8", "method": "MOBILE_MONEY", "amount_xof": 12000, "tendered_xof": 12000, "change_xof": 0, "provider": "ORANGE_MONEY", "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:46:12.337015+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "c653bebf-1379-418c-9c8b-d392e0067238", "fne_status": null, "warnings": []}	2026-10-19 14:46:12.422837+00	2026-10-19 14:46:12.422843+00
pay-9187a7af-42c4-4b1e-98df-51cf420ae7c0-1792421253382-b7900w1	/orders/9187a7af-42c4-4b1e-98df-51cf420ae7c0/payments		201	{"payment": {"id": "6fad81ff-5ef5-4f76-8d93-b3baab109246", "order_id": "9187a7af-42c4-4b1e-98df-51cf420ae7c0", "method": "MOBILE_MONEY", "amount_xof": 9000, "tendered_xof": 9000, "change_xof": 0, "provider": "MOOV", "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:47:33.410257+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": false, "print_job_id": "e3fda46a-07ca-4f15-b43a-aee180f50eed", "fne_status": null, "warnings": []}	2026-10-19 14:47:33.549789+00	2026-10-19 14:47:33.549797+00
pay-f1c7d23d-fe31-429b-8723-b5582ccba29c-1792421488616-om9effg	/orders/f1c7d23d-fe31-429b-8723-b5582ccba29c/payments		201	{"payment": {"id": "8e962b5a-1289-45e0-98f8-a11d6cdd718a", "order_id": "f1c7d23d-fe31-429b-8723-b5582ccba29c", "method": "CASH", "amount_xof": 12000, "tendered_xof": 15000, "change_xof": 3000, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:51:28.644774+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 3000, "drawer_opened": true, "print_job_id": "12ae39bf-b451-4669-8543-ff8f1e42af25", "fne_status": null, "warnings": []}	2026-10-19 14:51:28.687397+00	2026-10-19 14:51:28.687406+00
pay-0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c-1792421585708-2s8t2rj	/orders/0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c/payments		201	{"payment": {"id": "0053d599-4c29-4019-b493-c6c794434838", "order_id": "0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c", "method": "CASH", "amount_xof": 7500, "tendered_xof": 10000, "change_xof": 2500, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:53:05.758535+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 2500, "drawer_opened": true, "print_job_id": "8094f858-f856-4b99-9437-a08e0a5760f1", "fne_status": "CERTIFIED", "warnings": []}	2026-10-19 14:53:06.657971+00	2026-10-19 14:53:06.65798+00
pay-4630958e-a91c-426c-8d21-13cc50daf48c-1792421632245-zo5dkhu	/orders/4630958e-a91c-426c-8d21-13cc50daf48c/payments		201	{"payment": {"id": "41641af7-f183-4c6e-b3a6-343c29a16a90", "order_id": "4630958e-a91c-426c-8d21-13cc50daf48c", "method": "CASH", "amount_xof": 5000, "tendered_xof": 5000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-19T14:53:52.272789+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "bfec0c40-1c73-45a8-a91a-89a64e9decee", "fne_status": null, "warnings": []}	2026-10-19 14:53:52.318997+00	2026-10-19 14:53:52.319006+00
pay-cfdf234b-e450-4b8d-a49a-863dc774908e-1792496038410-g09x4hh	/orders/cfdf234b-e450-4b8d-a49a-863dc774908e/payments		201	{"payment": {"id": "4c232eb6-f36a-4931-ab15-ced6028bb8c9", "order_id": "cfdf234b-e450-4b8d-a49a-863dc774908e", "method": "CASH", "amount_xof": 6000, "tendered_xof": 6000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-20T11:33:58.462003+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "f4c8981f-95c4-43cf-8a04-c3554cc023bb", "fne_status": "CERTIFIED", "warnings": []}	2026-10-20 11:33:59.491718+00	2026-10-20 11:33:59.491729+00
pay-355aa3fe-84db-4a21-8310-a24e00d52726-1792514510218-rdeyu32	/orders/355aa3fe-84db-4a21-8310-a24e00d52726/payments		201	{"payment": {"id": "c35cbde7-7bb8-4aac-985b-92ff31fff7e8", "order_id": "355aa3fe-84db-4a21-8310-a24e00d52726", "method": "CASH", "amount_xof": 3500, "tendered_xof": 3500, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-20T16:41:50.252568+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "e7ca8159-8857-4423-9676-aba154fc5f03", "fne_status": null, "warnings": []}	2026-10-20 16:41:50.338898+00	2026-10-20 16:41:50.338906+00
pay-9d70470c-a448-4666-8a3b-26a894e407ad-1792696258453-h25hzfw	/orders/9d70470c-a448-4666-8a3b-26a894e407ad/payments		201	{"payment": {"id": "0099ca67-a281-462c-8219-6f7866a594af", "order_id": "9d70470c-a448-4666-8a3b-26a894e407ad", "method": "CASH", "amount_xof": 3500, "tendered_xof": 3500, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-22T19:10:58.526716+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "751db13a-b8e6-4693-bfb9-2adb0e9dc981", "fne_status": null, "warnings": []}	2026-10-22 19:10:58.682598+00	2026-10-22 19:10:58.682635+00
pay-c259aa5a-5c56-48e4-af2d-2cd301af43d8-1792696272162-f8112t8	/orders/c259aa5a-5c56-48e4-af2d-2cd301af43d8/payments		201	{"payment": {"id": "f242cc60-ae41-4eb8-bdc1-06a66f39c670", "order_id": "c259aa5a-5c56-48e4-af2d-2cd301af43d8", "method": "CASH", "amount_xof": 7000, "tendered_xof": 7000, "change_xof": 0, "provider": null, "reference": null, "status": "CAPTURED", "created_at": "2026-10-22T19:11:12.220540+00:00"}, "order_status": "PAID", "remaining_due_xof": 0, "change_xof": 0, "drawer_opened": true, "print_job_id": "47df885c-a9f9-424c-8473-76cf196586bb", "fne_status": null, "warnings": []}	2026-10-22 19:11:12.327157+00	2026-10-22 19:11:12.32717+00
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
7e70b382-d15d-44a3-a096-51c6023c49b5	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	ebb5f404-2267-4fa1-bd71-dd9e54707294	10.000	4000	40000	2026-10-22 16:43:35.014833+00	2026-10-22 16:43:35.01485+00
cfc34e5e-2d8d-41b8-930f-e7de57eb4525	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	0e520485-53a3-403a-8dc8-547417bb83e4	20.000	960	19200	2026-10-22 16:43:35.014865+00	2026-10-22 16:43:35.014868+00
24ae8c18-ea54-43b3-b50a-c597cef68f88	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	258570a6-aee0-4adb-a7e1-526f56b06506	10.000	800	8000	2026-10-22 16:43:35.015084+00	2026-10-22 16:43:35.015087+00
1e9dfa85-54fc-41a5-b1b6-c71efabddcc8	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	5e5c8e90-160b-4766-abc5-0b06087c6456	20.000	500	10000	2026-10-22 16:43:35.015098+00	2026-10-22 16:43:35.015101+00
e5f229dd-66b2-469b-a68c-43af6900f39c	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	30.000	556	16680	2026-10-22 16:43:35.015109+00	2026-10-22 16:43:35.015113+00
b6194fb5-be22-44e0-834b-38619672d53f	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	e4af9701-0d10-404a-9371-a0e7c84ec8f1	10.000	5500	55000	2026-10-22 16:43:35.015122+00	2026-10-22 16:43:35.015125+00
7cb7dc65-5bc3-4f30-9474-ff9309505c5d	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	8353e03f-35a0-44f9-ad7a-5c4336f90725	20.000	3000	60000	2026-10-22 16:43:35.015133+00	2026-10-22 16:43:35.015136+00
51deb766-ace7-4104-897c-ca7e4f2731ba	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	8353e03f-35a0-44f9-ad7a-5c4336f90725	20.000	3000	60000	2026-10-22 16:43:35.015144+00	2026-10-22 16:43:35.015147+00
7b940e18-82e4-42bb-9134-ebea09737418	7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	a4cbfa56-e146-4cec-b536-34c376c34e28	10.000	1540	15400	2026-10-22 16:43:35.015155+00	2026-10-22 16:43:35.015158+00
\.


--
-- Data for Name: market_purchase_lists; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.market_purchase_lists (id, business_date, status, created_by_user_id, validated_by_user_id, total_budget_xof, notes, created_at, updated_at) FROM stdin;
7f5f8762-12dc-46d6-ab53-bf89ecea8f7f	2026-10-22	COMPLETED	a3e01053-c2ad-4631-910a-0eb48345e5b1	4b5224bf-057a-4654-b13e-0e65ff403161	284280	\N	2026-10-22 16:43:34.939219+00	2026-10-22 16:47:00.515583+00
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
6a1c51f4-6477-4bf1-969d-6e160d91fc09	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	243e0846-82f3-47e2-8e25-77e32ec08ef3	Frites + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:28:02.775603+00	\N	\N	\N	2026-10-06 11:28:02.776883+00	2026-10-06 11:28:02.776899+00
05724252-3c5b-44a0-bd40-0cac6287d211	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	07f0b52a-05a5-4410-ad92-6c1b643c6110	Salade Panachée + Boeuf	Spécial Salade	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:28:02.898023+00	\N	\N	\N	2026-10-06 11:28:02.899164+00	2026-10-06 11:28:02.899183+00
0c7909cf-44e5-43d8-916b-7cf7cb48f177	4dca0121-6712-4315-8098-c7cb86dad49d	eef3b439-112e-485e-a7b6-0d7cd40198bf	Sauce Feuille + Poulet	Spécial Sauce	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:28:45.59688+00	\N	\N	\N	2026-10-06 11:28:45.598179+00	2026-10-06 11:28:45.598198+00
1d75d76b-8dad-4410-83f1-b5e7e8935356	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:28:02.613119+00	\N	\N	\N	2026-10-06 11:28:02.61622+00	2026-10-06 11:28:02.616265+00
cecee6b7-6b3d-438a-a7a1-edb25a8df644	4dca0121-6712-4315-8098-c7cb86dad49d	c39717d7-bb67-4780-9bbe-47a00cc2f12b	Dégué	Spécial Desserts	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:28:45.752795+00	\N	\N	\N	2026-10-06 11:28:45.753924+00	2026-10-06 11:28:45.753937+00
9c231e6e-f5b6-48ad-89d9-491354a229bc	4dca0121-6712-4315-8098-c7cb86dad49d	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:28:45.86565+00	\N	\N	\N	2026-10-06 11:28:45.866858+00	2026-10-06 11:28:45.866872+00
a467acd3-759c-497a-be87-091ce6c653b1	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	f8c3551b-ce83-449e-a6c1-a640f89e8e68	Kabato Kope + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:29:23.458295+00	\N	\N	\N	2026-10-06 11:29:23.459542+00	2026-10-06 11:29:23.459555+00
972d450b-52f5-4ef9-8266-9c65babdf378	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	cd5cc4d5-6a6b-45d7-9c3d-9b4d5274d955	Kabato Lafri + Tripe	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:29:23.579057+00	\N	\N	\N	2026-10-06 11:29:23.580475+00	2026-10-06 11:29:23.580504+00
c77f25ca-f040-46d8-afc9-696221641ae4	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	Salade Panachée + Sosso	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:29:23.72403+00	\N	\N	\N	2026-10-06 11:29:23.725193+00	2026-10-06 11:29:23.725209+00
3df78cc4-400b-4f7c-8de1-f74788ca3419	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	3cc363fc-99c1-4779-806b-e6d10019e507	Yassa + Boeuf	Spécial Sénégal	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:29:23.856421+00	\N	\N	\N	2026-10-06 11:29:23.857722+00	2026-10-06 11:29:23.857736+00
85dea713-026e-4ed8-99fa-72a1e9604ee5	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:29:23.962104+00	\N	\N	\N	2026-10-06 11:29:23.963209+00	2026-10-06 11:29:23.963245+00
3e607162-05f7-4db6-aea6-9ede78e3f561	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 11:29:24.06864+00	\N	\N	\N	2026-10-06 11:29:24.069695+00	2026-10-06 11:29:24.069708+00
fdc1b12e-9132-444b-9f07-d929dbf2fac4	c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd	243e0846-82f3-47e2-8e25-77e32ec08ef3	Frites + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 12:02:40.73382+00	\N	\N	\N	2026-10-06 12:02:40.736256+00	2026-10-06 12:02:40.736269+00
9102aa41-6288-4462-b8ab-4001a433877f	c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd	4f182459-6a5a-492e-8037-46ce31108923	Frites + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 12:02:40.803871+00	\N	\N	\N	2026-10-06 12:02:40.804797+00	2026-10-06 12:02:40.804809+00
d331d990-5f16-43ef-bd75-042e2fc1f648	c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd	1dcc3350-2fdb-4653-a60f-ec1212bb682e	Alloco + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 12:02:40.86235+00	\N	\N	\N	2026-10-06 12:02:40.866663+00	2026-10-06 12:02:40.866673+00
98e6917a-0cec-4e13-bd49-e692079ce347	c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd	7e2e9acc-4cb0-4222-8e04-e09402820956	Alloco + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 12:02:40.935432+00	\N	\N	\N	2026-10-06 12:02:40.936187+00	2026-10-06 12:02:40.936197+00
57cbe577-16ce-4a6b-beae-2e0d0957b337	b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	f01823cb-78e6-4174-9d72-aadfd2436a19	Kabato Lafri + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:30:35.261714+00	\N	\N	\N	2026-10-06 14:30:35.264899+00	2026-10-06 14:30:35.26491+00
5b81f0aa-9c71-4d3f-9632-8c4f07aff1ba	b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:30:35.367481+00	\N	\N	\N	2026-10-06 14:30:35.367955+00	2026-10-06 14:30:35.367959+00
1e2f199b-a75c-4148-9eb7-a794f5877018	b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	4f182459-6a5a-492e-8037-46ce31108923	Frites + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:30:35.436599+00	\N	\N	\N	2026-10-06 14:30:35.437621+00	2026-10-06 14:30:35.437637+00
a7085b71-0070-462e-b7a0-15ede34cfb7a	b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	659bc0ec-f84d-4116-a67b-d586d5673641	Attiéké + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:30:35.49554+00	\N	\N	\N	2026-10-06 14:30:35.496192+00	2026-10-06 14:30:35.496203+00
b775560e-0fdb-4776-9d72-504d3c2ef3de	b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	dbf93f42-7b4c-4c7e-a873-10f18a2151b0	Igname frite + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:30:35.568307+00	\N	\N	\N	2026-10-06 14:30:35.568936+00	2026-10-06 14:30:35.568943+00
4427f74c-1f8b-433c-83e4-55a1607e244f	5c853bf0-1866-4f88-a27d-f1fb5caca8f6	0c8c099a-1d4b-4c78-be70-a2f846f9ce63	Kabato Dah + Mouton	Spécial Kabato	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:31:30.833659+00	\N	\N	\N	2026-10-06 14:31:30.834543+00	2026-10-06 14:31:30.834553+00
2bccabcc-71db-459c-b58c-963db731da21	5c853bf0-1866-4f88-a27d-f1fb5caca8f6	78a775c5-9a24-4760-a370-483ebc35cd3d	Kabato Lafri + Boeuf	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:31:30.939571+00	\N	\N	\N	2026-10-06 14:31:30.940475+00	2026-10-06 14:31:30.940487+00
12b14d3e-043e-4753-92e5-9cb1b07895da	5c853bf0-1866-4f88-a27d-f1fb5caca8f6	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:31:31.017021+00	\N	\N	\N	2026-10-06 14:31:31.018653+00	2026-10-06 14:31:31.018664+00
7f69875d-186d-4540-bb1e-9cd0131738b6	5c853bf0-1866-4f88-a27d-f1fb5caca8f6	3cc363fc-99c1-4779-806b-e6d10019e507	Yassa + Boeuf	Spécial Sénégal	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:31:31.074814+00	\N	\N	\N	2026-10-06 14:31:31.075676+00	2026-10-06 14:31:31.075688+00
d6a13999-ab40-41aa-8d60-10335f230de1	5c853bf0-1866-4f88-a27d-f1fb5caca8f6	4fa1d747-7bc0-4ec1-b54e-371169717ec3	Salade Panachée + Poisson braisé	Spécial Salade	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:31:31.154816+00	\N	\N	\N	2026-10-06 14:31:31.155568+00	2026-10-06 14:31:31.155577+00
5c56d6c6-70f9-4dc5-9ec1-dcc68f39cb50	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:32:06.480615+00	\N	\N	\N	2026-10-06 14:32:06.481208+00	2026-10-06 14:32:06.481215+00
1acb0446-8b20-4362-8689-b8c96f82d926	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	243e0846-82f3-47e2-8e25-77e32ec08ef3	Frites + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:32:06.571202+00	\N	\N	\N	2026-10-06 14:32:06.572275+00	2026-10-06 14:32:06.572289+00
9305284b-32d8-447f-9d80-46f6b143acf1	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	8a5290af-0957-4c14-a42b-88c6f7069761	Frites + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:32:06.661595+00	\N	\N	\N	2026-10-06 14:32:06.662446+00	2026-10-06 14:32:06.662458+00
db49c978-9039-4280-9fb2-9ba9b1839259	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	659bc0ec-f84d-4116-a67b-d586d5673641	Attiéké + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:32:06.734313+00	\N	\N	\N	2026-10-06 14:32:06.735058+00	2026-10-06 14:32:06.735068+00
10dc03af-0cf2-4220-a739-d794065840f6	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	e2028931-16ad-47cd-a58c-03359d67788d	Couscous + Mouton	Spécial Oriental	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:32:06.824389+00	\N	\N	\N	2026-10-06 14:32:06.825167+00	2026-10-06 14:32:06.825179+00
03a3357b-8fe5-4e51-a2a4-02facf51ed25	64526137-92a1-418d-9d03-6393030d1f1f	d725ab54-f42b-41c9-9da6-fd327076f301	Yassa + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:33:57.81293+00	\N	\N	\N	2026-10-06 14:33:57.813622+00	2026-10-06 14:33:57.813629+00
07633e84-d78c-4277-a497-dc062bbb5de7	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	4c60f063-cc76-4d22-a8ae-00001fdf4675	Couscous + Boeuf	Spécial Oriental	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:32:06.908443+00	\N	\N	\N	2026-10-06 14:32:06.909551+00	2026-10-06 14:32:06.909565+00
63b3636c-1297-4a04-8acd-b69b5ea50e2f	64526137-92a1-418d-9d03-6393030d1f1f	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:33:57.709859+00	\N	\N	\N	2026-10-06 14:33:57.710999+00	2026-10-06 14:33:57.71102+00
5354ee5e-ddfd-455a-81a9-bc5c48efdd40	64526137-92a1-418d-9d03-6393030d1f1f	59a3f6b4-9692-439f-ba35-8c9211bbff90	Yassa + Poulet	Spécial Sénégal	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 14:33:57.768607+00	\N	\N	\N	2026-10-06 14:33:57.769391+00	2026-10-06 14:33:57.7694+00
0b5fbcdc-9fff-458a-a007-8790bfeadfd5	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	78a775c5-9a24-4760-a370-483ebc35cd3d	Kabato Lafri + Boeuf	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 15:19:59.538883+00	\N	\N	\N	2026-10-06 15:19:59.558331+00	2026-10-06 15:19:59.558439+00
d20fcd9b-d2a4-4dd4-8b89-c5acf2abe30c	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	78a775c5-9a24-4760-a370-483ebc35cd3d	Kabato Lafri + Boeuf	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 15:20:57.45722+00	\N	\N	\N	2026-10-06 15:20:57.457789+00	2026-10-06 15:20:57.457795+00
d753772c-3739-4002-aaeb-a760b062b921	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	78a775c5-9a24-4760-a370-483ebc35cd3d	Kabato Lafri + Boeuf	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-06 15:34:56.696172+00	\N	\N	\N	2026-10-06 15:34:56.700169+00	2026-10-06 15:34:56.700178+00
6a012ac6-a11e-4498-ad81-f49f56185f2d	c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a	cd408593-401c-46d0-8507-624f0342f05a	Couscous + Poisson	Spécial Oriental	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 10:47:29.105372+00	\N	\N	\N	2026-10-08 10:47:29.105968+00	2026-10-08 10:47:29.105973+00
a4b93ba1-fee7-4204-8d95-748975e2190a	c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a	e2028931-16ad-47cd-a58c-03359d67788d	Couscous + Mouton	Spécial Oriental	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 10:47:29.283089+00	\N	\N	\N	2026-10-08 10:47:29.283851+00	2026-10-08 10:47:29.28386+00
20e66ef5-9387-41b4-9db6-6542a6c89df3	c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 10:47:29.385798+00	\N	\N	\N	2026-10-08 10:47:29.386444+00	2026-10-08 10:47:29.386449+00
6bdac272-78d7-454e-88c9-8bbe5384fffa	c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a	c39717d7-bb67-4780-9bbe-47a00cc2f12b	Dégué	Spécial Desserts	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 10:47:29.478978+00	\N	\N	\N	2026-10-08 10:47:29.479558+00	2026-10-08 10:47:29.479564+00
c2128174-33e6-43f8-b066-70fbf44d2a26	21a1947c-5da6-4a14-ae3f-a931b866bb53	17f3e970-a0fa-4fac-8a67-e727f9b6e1e5	Kabato Lafri + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 10:50:30.113009+00	\N	\N	\N	2026-10-08 10:50:30.113889+00	2026-10-08 10:50:30.113895+00
6019f375-ed4a-4fa6-8512-8ba216d4305d	21a1947c-5da6-4a14-ae3f-a931b866bb53	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 10:50:30.203058+00	\N	\N	\N	2026-10-08 10:50:30.203624+00	2026-10-08 10:50:30.203629+00
446300e4-108f-4fb9-a437-295aa8a7627b	21a1947c-5da6-4a14-ae3f-a931b866bb53	edc21662-09f3-4f30-acb3-714a69cac870	Igname bouillie + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 10:50:30.300278+00	\N	\N	\N	2026-10-08 10:50:30.300951+00	2026-10-08 10:50:30.300958+00
a875f631-1aad-41ac-b5ef-d4e9e8b5116b	e6ff5588-1a97-409f-b651-8dcd1ec5135b	934dde37-9033-45e6-86ed-7cdd2215b18e	Kabato Dah + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:33:50.935118+00	\N	\N	\N	2026-10-08 14:33:50.943499+00	2026-10-08 14:33:50.94351+00
151ad44b-07ca-4c27-a654-0323faa9847b	e6ff5588-1a97-409f-b651-8dcd1ec5135b	0c8c099a-1d4b-4c78-be70-a2f846f9ce63	Kabato Dah + Mouton	Spécial Kabato	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:33:51.178766+00	\N	\N	\N	2026-10-08 14:33:51.179666+00	2026-10-08 14:33:51.179677+00
4378c8a6-422e-4960-9b3b-2ac2b0b1a352	e6ff5588-1a97-409f-b651-8dcd1ec5135b	5a718736-9643-4ae4-824e-1c05f6d093dd	Kabato Kope + Mouton	Spécial Kabato	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:33:51.404919+00	\N	\N	\N	2026-10-08 14:33:51.405797+00	2026-10-08 14:33:51.405832+00
e3fab71b-b539-4ba7-bb7d-7dbcab053644	e6ff5588-1a97-409f-b651-8dcd1ec5135b	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:33:51.59578+00	\N	\N	\N	2026-10-08 14:33:51.596605+00	2026-10-08 14:33:51.596621+00
93692203-4e85-4e26-b2d5-a5e8308eed51	e6ff5588-1a97-409f-b651-8dcd1ec5135b	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	3	0.00	1500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:33:51.79461+00	\N	\N	\N	2026-10-08 14:33:51.795355+00	2026-10-08 14:33:51.795363+00
46e136ee-bbf7-4b07-943e-2e3977562cf6	1ae79c99-2c11-40f4-9b4e-6948b5256aed	e2551239-6d21-4a43-aac3-f435b261884e	Frites + Boeuf	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:02.330215+00	\N	\N	\N	2026-10-08 14:36:02.331351+00	2026-10-08 14:36:02.331362+00
c77bbda0-02d1-406b-8574-635b5f91e893	1ae79c99-2c11-40f4-9b4e-6948b5256aed	46a09e73-28f4-4df9-984a-95ac939cfe1a	Attiéké + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:02.477651+00	\N	\N	\N	2026-10-08 14:36:02.478363+00	2026-10-08 14:36:02.47837+00
a6b0a7ef-5441-4612-8bff-481292fa3917	1ae79c99-2c11-40f4-9b4e-6948b5256aed	ee109fb4-61db-4bd2-803d-911a26183e28	Igname frite + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:02.627488+00	\N	\N	\N	2026-10-08 14:36:02.62831+00	2026-10-08 14:36:02.628317+00
34ae8946-65cb-4182-a54b-cb1da219dd5b	1ae79c99-2c11-40f4-9b4e-6948b5256aed	1dcc3350-2fdb-4653-a60f-ec1212bb682e	Alloco + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:02.783708+00	\N	\N	\N	2026-10-08 14:36:02.784386+00	2026-10-08 14:36:02.784396+00
6db34d42-4166-4d91-9cab-5975584a5ab6	1ae79c99-2c11-40f4-9b4e-6948b5256aed	c39717d7-bb67-4780-9bbe-47a00cc2f12b	Dégué	Spécial Desserts	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:02.920114+00	\N	\N	\N	2026-10-08 14:36:02.920702+00	2026-10-08 14:36:02.92071+00
a3fd6878-a50a-4a7b-88b3-6fa9b14945e0	1ae79c99-2c11-40f4-9b4e-6948b5256aed	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:03.048476+00	\N	\N	\N	2026-10-08 14:36:03.04912+00	2026-10-08 14:36:03.049126+00
7ce53cf8-fbfd-4792-8ed2-e96b388a31c6	1ae79c99-2c11-40f4-9b4e-6948b5256aed	b8747001-a8c8-4cc8-b623-b7ea096ff33d	Lait	Spécial Desserts	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:03.166906+00	\N	\N	\N	2026-10-08 14:36:03.167752+00	2026-10-08 14:36:03.167764+00
1702ffc1-934d-4b8b-acfc-7e72de785bf5	1ae79c99-2c11-40f4-9b4e-6948b5256aed	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:03.319039+00	\N	\N	\N	2026-10-08 14:36:03.321847+00	2026-10-08 14:36:03.321855+00
93069097-ee32-4d2c-a7c1-efbc6471764c	1ae79c99-2c11-40f4-9b4e-6948b5256aed	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:03.467463+00	\N	\N	\N	2026-10-08 14:36:03.468606+00	2026-10-08 14:36:03.468625+00
16f28926-701a-443d-8ca1-d7203764e656	1ae79c99-2c11-40f4-9b4e-6948b5256aed	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:36:03.617144+00	\N	\N	\N	2026-10-08 14:36:03.618151+00	2026-10-08 14:36:03.618163+00
7dc13855-7de9-4d1b-bd32-406c6386193b	076109cb-177f-408e-b8d2-1a2ca7c82b9b	19a0e1b1-b889-4cf6-b553-017f739929aa	Couscous + Poulet	Spécial Oriental	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:16.182043+00	\N	\N	\N	2026-10-08 14:37:16.182872+00	2026-10-08 14:37:16.18288+00
3838d2b9-a2c3-4be1-a44b-9fa1e5d35d5f	076109cb-177f-408e-b8d2-1a2ca7c82b9b	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:16.419677+00	\N	\N	\N	2026-10-08 14:37:16.420587+00	2026-10-08 14:37:16.4206+00
172c9b9c-6e6b-4ea7-ad32-2b8e0b2e0e0d	076109cb-177f-408e-b8d2-1a2ca7c82b9b	46a09e73-28f4-4df9-984a-95ac939cfe1a	Attiéké + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:16.596036+00	\N	\N	\N	2026-10-08 14:37:16.596693+00	2026-10-08 14:37:16.596703+00
0e8cdaed-940b-44fc-8f50-9c63815b427f	076109cb-177f-408e-b8d2-1a2ca7c82b9b	ad312dc8-07cc-4429-ab36-054466502320	Sauce Légume + Poulet	Spécial Sauce	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:16.734238+00	\N	\N	\N	2026-10-08 14:37:16.73497+00	2026-10-08 14:37:16.734979+00
321a6a73-49ee-4968-8075-e3b02ade0c05	076109cb-177f-408e-b8d2-1a2ca7c82b9b	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:16.89825+00	\N	\N	\N	2026-10-08 14:37:16.899379+00	2026-10-08 14:37:16.899393+00
a8e09b2d-fb2a-4d80-bc1a-4f90b7e0c5e4	076109cb-177f-408e-b8d2-1a2ca7c82b9b	c39717d7-bb67-4780-9bbe-47a00cc2f12b	Dégué	Spécial Desserts	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:17.065764+00	\N	\N	\N	2026-10-08 14:37:17.066417+00	2026-10-08 14:37:17.066423+00
b86e5341-4687-4c46-ac9f-9b8663251295	076109cb-177f-408e-b8d2-1a2ca7c82b9b	b8747001-a8c8-4cc8-b623-b7ea096ff33d	Lait	Spécial Desserts	1000	2	0.00	2000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:17.23005+00	\N	\N	\N	2026-10-08 14:37:17.230631+00	2026-10-08 14:37:17.230638+00
4582e8fd-ac08-465b-89ca-cf65df2ee94b	076109cb-177f-408e-b8d2-1a2ca7c82b9b	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:17.349787+00	\N	\N	\N	2026-10-08 14:37:17.350636+00	2026-10-08 14:37:17.350648+00
08afc7a2-f305-46c9-9aa8-3ae565bf418b	076109cb-177f-408e-b8d2-1a2ca7c82b9b	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:17.576612+00	\N	\N	\N	2026-10-08 14:37:17.577334+00	2026-10-08 14:37:17.577341+00
de9cdf62-6ffc-4901-a1d1-5ab8a6f6a1f7	076109cb-177f-408e-b8d2-1a2ca7c82b9b	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:37:17.792997+00	\N	\N	\N	2026-10-08 14:37:17.793868+00	2026-10-08 14:37:17.793875+00
dbfbf622-5181-4cd8-a9cd-e102bb1ed558	db5be098-d0bf-42f8-91e8-9a1ecd858825	e2551239-6d21-4a43-aac3-f435b261884e	Frites + Boeuf	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:43:08.576504+00	\N	\N	\N	2026-10-08 14:43:08.577969+00	2026-10-08 14:43:08.57798+00
bd666ef0-7065-4cf8-b783-8cddd5f984dd	db5be098-d0bf-42f8-91e8-9a1ecd858825	46a09e73-28f4-4df9-984a-95ac939cfe1a	Attiéké + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:43:08.753495+00	\N	\N	\N	2026-10-08 14:43:08.754406+00	2026-10-08 14:43:08.754416+00
814de8e4-3ffa-4c6d-a0ac-4ab8eb68a6ea	db5be098-d0bf-42f8-91e8-9a1ecd858825	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:43:08.873897+00	\N	\N	\N	2026-10-08 14:43:08.874719+00	2026-10-08 14:43:08.87473+00
4edefae4-f94d-4d6b-ab33-2e13d82138cf	db5be098-d0bf-42f8-91e8-9a1ecd858825	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:43:09.005511+00	\N	\N	\N	2026-10-08 14:43:09.006358+00	2026-10-08 14:43:09.006367+00
0546e104-6133-4579-92ef-f6747acbf45b	db5be098-d0bf-42f8-91e8-9a1ecd858825	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	2	0.00	2000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 14:43:09.133128+00	\N	\N	\N	2026-10-08 14:43:09.133824+00	2026-10-08 14:43:09.133834+00
5deace54-8864-44d1-95f5-a6ebe4d39638	9a9fc6d5-9fb0-4031-929e-50035995d1db	fbb74d1d-e719-4478-b4fb-df4a903e41d5	Kabato Kope + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 15:04:46.627668+00	\N	\N	\N	2026-10-08 15:04:46.630588+00	2026-10-08 15:04:46.630603+00
78e58766-d32c-4c2b-a962-b9c37d131f5f	9a9fc6d5-9fb0-4031-929e-50035995d1db	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 15:04:46.804998+00	\N	\N	\N	2026-10-08 15:04:46.805614+00	2026-10-08 15:04:46.80565+00
742c3ee8-ae3e-4a9b-ab92-1d6077871d05	39bd2f25-6504-419b-b010-af921b9e733a	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	Salade Panachée + Sosso	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:09:31.264334+00	\N	\N	\N	2026-10-13 11:09:31.266985+00	2026-10-13 11:09:31.266994+00
c745a040-3ad3-43d6-9716-ecbbd7a5362a	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:48.287154+00	\N	\N	\N	2026-10-13 11:29:48.287706+00	2026-10-13 11:29:48.287711+00
2203f056-5bdb-4db6-860c-ec0098fb976f	9a9fc6d5-9fb0-4031-929e-50035995d1db	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 15:04:46.994089+00	\N	\N	\N	2026-10-08 15:04:46.994978+00	2026-10-08 15:04:46.994987+00
57be927e-2330-43ad-96f1-dea60e4adbdb	39bd2f25-6504-419b-b010-af921b9e733a	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:09:31.538953+00	\N	\N	\N	2026-10-13 11:09:31.539525+00	2026-10-13 11:09:31.539531+00
1f1d6002-b9ff-4446-92e0-5d144050e407	c7b4ce76-37d6-4963-83b6-5da7c270aa02	355d16bb-9d61-4ed9-991e-66e0cae3d29e	Sauce Feuille + Mouton	Spécial Sauce	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:13.073473+00	\N	\N	\N	2026-10-13 11:29:13.076218+00	2026-10-13 11:29:13.076225+00
ab726aff-b107-4730-9b4d-2d2731937b56	c7b4ce76-37d6-4963-83b6-5da7c270aa02	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:13.38624+00	\N	\N	\N	2026-10-13 11:29:13.387002+00	2026-10-13 11:29:13.387008+00
3358b33b-c6bd-4848-9c6b-cdbca5cc4750	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:48.192799+00	\N	\N	\N	2026-10-13 11:29:48.193378+00	2026-10-13 11:29:48.193383+00
b271956a-663e-41e9-8435-751333d9bd6d	867b6c58-13d3-4af8-8f2e-094ae7f69f2c	ad312dc8-07cc-4429-ab36-054466502320	Sauce Légume + Poulet	Spécial Sauce	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-08 15:05:17.802274+00	\N	\N	\N	2026-10-08 15:05:17.802919+00	2026-10-08 15:05:17.802928+00
f81254a9-7d59-4854-a8c4-fded26287cfd	c7b4ce76-37d6-4963-83b6-5da7c270aa02	90ad3b70-6c4f-4050-a3c5-d157cd072af5	Sauce Légume + Poisson	Spécial Sauce	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:13.181736+00	\N	\N	\N	2026-10-13 11:29:13.18241+00	2026-10-13 11:29:13.182415+00
7f941c08-f4bd-43a8-9552-bbf86db49fa3	c7b4ce76-37d6-4963-83b6-5da7c270aa02	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:13.479761+00	\N	\N	\N	2026-10-13 11:29:13.480512+00	2026-10-13 11:29:13.48052+00
42eb2f06-c5ba-4efe-96f3-6ce14641b0c8	39bd2f25-6504-419b-b010-af921b9e733a	da7a9d7b-64d7-46e9-9a66-fb411d1976e5	Salade Panachée + Poulet	Spécial Salade	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:09:31.407955+00	\N	\N	\N	2026-10-13 11:09:31.40877+00	2026-10-13 11:09:31.40878+00
fa4f3cd0-29cc-4384-9751-6ef4e7c89ee3	39bd2f25-6504-419b-b010-af921b9e733a	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:09:31.686253+00	\N	\N	\N	2026-10-13 11:09:31.687094+00	2026-10-13 11:09:31.687103+00
135fff4f-cfed-4dee-bb68-00c99c0986eb	c7b4ce76-37d6-4963-83b6-5da7c270aa02	4160714b-10ca-4c4f-8b8a-d4c2cba53724	Sauce Dah + Poulet	Spécial Sauce	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:13.285894+00	\N	\N	\N	2026-10-13 11:29:13.286442+00	2026-10-13 11:29:13.286447+00
d705c9bf-1800-4807-9e10-1788820cf2a4	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	e2551239-6d21-4a43-aac3-f435b261884e	Frites + Boeuf	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:47.622692+00	\N	\N	\N	2026-10-13 11:29:47.623309+00	2026-10-13 11:29:47.623318+00
fe538e79-a17d-4aa4-acce-9d7570ebb5d7	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	28e30eaa-c921-4371-8e7e-f0c7d3d1e011	Alloco + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:47.808323+00	\N	\N	\N	2026-10-13 11:29:47.809006+00	2026-10-13 11:29:47.809014+00
4d957ba9-4aa6-4932-abfb-b10ca4211bae	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	fac18978-1efd-4b64-99a7-75758a3d73c6	Attiéké + Boeuf	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:47.993027+00	\N	\N	\N	2026-10-13 11:29:47.993782+00	2026-10-13 11:29:47.993787+00
863d789a-8cef-41b4-aaec-2d188e547ce5	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	1dcc3350-2fdb-4653-a60f-ec1212bb682e	Alloco + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 11:29:48.099697+00	\N	\N	\N	2026-10-13 11:29:48.100422+00	2026-10-13 11:29:48.100429+00
a18a82f7-702b-4064-8732-461c7c043f31	e39da534-1326-47b7-a6e2-b3bdccfbd904	17f3e970-a0fa-4fac-8a67-e727f9b6e1e5	Kabato Lafri + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 14:51:09.510334+00	\N	\N	\N	2026-10-13 14:51:09.514321+00	2026-10-13 14:51:09.514331+00
3887aaf8-a5c8-4e05-abbc-b6f9a9d6ab3c	e39da534-1326-47b7-a6e2-b3bdccfbd904	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 14:51:09.680696+00	\N	\N	\N	2026-10-13 14:51:09.681806+00	2026-10-13 14:51:09.681844+00
684b573e-627c-4a7f-9e71-6465004fa91d	e39da534-1326-47b7-a6e2-b3bdccfbd904	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 14:51:09.886391+00	\N	\N	\N	2026-10-13 14:51:09.887097+00	2026-10-13 14:51:09.887104+00
4e2a14ab-cc7c-4812-a9e2-24601fde4a6b	e39da534-1326-47b7-a6e2-b3bdccfbd904	19a0e1b1-b889-4cf6-b553-017f739929aa	Couscous + Poulet	Spécial Oriental	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 14:51:09.970938+00	\N	\N	\N	2026-10-13 14:51:09.971687+00	2026-10-13 14:51:09.971697+00
e962a6b9-8f15-4fcd-b60e-c70bf13ce481	ea858ea2-6771-49c3-b09b-253f7cadb4e4	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 14:51:34.493206+00	\N	\N	\N	2026-10-13 14:51:34.493998+00	2026-10-13 14:51:34.494007+00
97b3392b-011f-4fde-bd2e-95febe4f0171	ea858ea2-6771-49c3-b09b-253f7cadb4e4	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	2	0.00	2000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 14:51:34.617987+00	\N	\N	\N	2026-10-13 14:51:34.618865+00	2026-10-13 14:51:34.618873+00
5e365cb1-23a4-4474-9044-e18644140997	ea858ea2-6771-49c3-b09b-253f7cadb4e4	d1ca497d-4d17-4b6f-b7a5-37d772e72507	Tchep + Poisson	Spécial Sénégal	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 14:51:34.718642+00	\N	\N	\N	2026-10-13 14:51:34.719374+00	2026-10-13 14:51:34.719383+00
086666f7-a764-4812-b874-9826423dbb45	ea858ea2-6771-49c3-b09b-253f7cadb4e4	d725ab54-f42b-41c9-9da6-fd327076f301	Yassa + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-13 14:51:34.812248+00	\N	\N	\N	2026-10-13 14:51:34.812788+00	2026-10-13 14:51:34.812793+00
38b38222-0e87-4f60-861a-3a20ef3dc6f8	1d99a39f-4263-4b0f-b6dd-6544080aab4a	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:18:58.152158+00	\N	\N	\N	2026-10-14 15:18:58.155159+00	2026-10-14 15:18:58.155168+00
babb9e2b-81fe-446e-9b48-c2fe6fc972f4	1d99a39f-4263-4b0f-b6dd-6544080aab4a	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	Salade Panachée + Sosso	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:18:58.272469+00	\N	\N	\N	2026-10-14 15:18:58.273429+00	2026-10-14 15:18:58.273441+00
dab2f615-2a70-4af4-9c2e-5f815e2540e7	1d99a39f-4263-4b0f-b6dd-6544080aab4a	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:18:58.432018+00	\N	\N	\N	2026-10-14 15:18:58.432851+00	2026-10-14 15:18:58.432861+00
748d475c-8653-4877-837a-ee4c9fe31737	1d99a39f-4263-4b0f-b6dd-6544080aab4a	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:18:58.556498+00	\N	\N	\N	2026-10-14 15:18:58.5574+00	2026-10-14 15:18:58.557411+00
4b324c72-17f3-4951-b7f7-f917c7b1530d	1d99a39f-4263-4b0f-b6dd-6544080aab4a	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:18:58.693771+00	\N	\N	\N	2026-10-14 15:18:58.694722+00	2026-10-14 15:18:58.694734+00
e0cc0c69-f1c3-4507-8c36-48b5a865dd3c	998f84b2-586b-47c9-98ce-bcd1becca088	edc21662-09f3-4f30-acb3-714a69cac870	Igname bouillie + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:20:43.355738+00	\N	\N	\N	2026-10-14 15:20:43.356446+00	2026-10-14 15:20:43.356453+00
3076529a-b556-457b-94de-0135c6483259	998f84b2-586b-47c9-98ce-bcd1becca088	d1ca497d-4d17-4b6f-b7a5-37d772e72507	Tchep + Poisson	Spécial Sénégal	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:20:43.53566+00	\N	\N	\N	2026-10-14 15:20:43.536854+00	2026-10-14 15:20:43.536868+00
d247412b-4251-43ed-aa65-3915ea1c1b0d	998f84b2-586b-47c9-98ce-bcd1becca088	4fa1d747-7bc0-4ec1-b54e-371169717ec3	Salade Panachée + Poisson braisé	Spécial Salade	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:20:43.646296+00	\N	\N	\N	2026-10-14 15:20:43.647144+00	2026-10-14 15:20:43.647154+00
9512a9e8-d86c-41e0-a5eb-6b23696a04e3	4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8	1cff1a75-2cd4-4f08-b161-df8e796b4831	Kabato Kope + Tripe	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:25:10.005246+00	\N	\N	\N	2026-10-14 15:25:10.006046+00	2026-10-14 15:25:10.006056+00
a506b07b-13af-47d9-a403-62b6dcb2f442	ce2dd852-2947-4e23-b62e-4d8df1a69490	1cff1a75-2cd4-4f08-b161-df8e796b4831	Kabato Kope + Tripe	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:32:31.532824+00	\N	\N	\N	2026-10-14 15:32:31.533691+00	2026-10-14 15:32:31.533699+00
98fd355a-9b64-4549-93c9-ae172607ec05	ce2dd852-2947-4e23-b62e-4d8df1a69490	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:32:31.706481+00	\N	\N	\N	2026-10-14 15:32:31.707485+00	2026-10-14 15:32:31.707497+00
92d76b7b-e01a-4b24-896c-b5f595d7ec6d	ce2dd852-2947-4e23-b62e-4d8df1a69490	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-14 15:32:31.823017+00	\N	\N	\N	2026-10-14 15:32:31.823728+00	2026-10-14 15:32:31.823737+00
00495238-f69c-4571-81bc-d9d72ad09b3c	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	cd5cc4d5-6a6b-45d7-9c3d-9b4d5274d955	Kabato Lafri + Tripe	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:08:44.014196+00	\N	\N	\N	2026-10-15 11:08:44.017952+00	2026-10-15 11:08:44.017961+00
9c53774b-dcaa-4e6f-bd52-6cff9becbe2c	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	4fa1d747-7bc0-4ec1-b54e-371169717ec3	Salade Panachée + Poisson braisé	Spécial Salade	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:08:44.163819+00	\N	\N	\N	2026-10-15 11:08:44.164541+00	2026-10-15 11:08:44.164548+00
64b22562-194e-477b-95e9-c05b70d1d6eb	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	Salade Panachée + Sosso	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:08:44.28369+00	\N	\N	\N	2026-10-15 11:08:44.284757+00	2026-10-15 11:08:44.28477+00
27d0b2c7-c0c3-49d3-a442-5b602f1e56a8	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:08:44.414014+00	\N	\N	\N	2026-10-15 11:08:44.415057+00	2026-10-15 11:08:44.41507+00
52f27e70-12e6-4be9-bbae-5703a7e5cb02	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:08:44.543525+00	\N	\N	\N	2026-10-15 11:08:44.543977+00	2026-10-15 11:08:44.543982+00
4a4b514e-91aa-4c97-b5cf-4e81bb072344	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	e2551239-6d21-4a43-aac3-f435b261884e	Frites + Boeuf	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:09:47.441678+00	\N	\N	\N	2026-10-15 11:09:47.442555+00	2026-10-15 11:09:47.442567+00
bc81b25c-e2a3-4bdb-982c-8e6565f78c57	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	46a09e73-28f4-4df9-984a-95ac939cfe1a	Attiéké + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:09:47.606627+00	\N	\N	\N	2026-10-15 11:09:47.607808+00	2026-10-15 11:09:47.608145+00
eec53167-02fb-4d83-99c3-fccd4fcfd5ac	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:09:47.85259+00	\N	\N	\N	2026-10-15 11:09:47.853748+00	2026-10-15 11:09:47.85376+00
e1b02577-917d-4dbd-af18-11331af961e5	ee578b03-ff99-40a0-9313-02085d248038	b3b6071a-76d0-4318-ab97-4a61d8a8ba8d	Kabato Dah + Tripe	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:28:00.225032+00	\N	\N	\N	2026-10-15 11:28:00.226732+00	2026-10-15 11:28:00.226741+00
7ac9c439-0089-49c2-9b6c-94596e07bf3b	ee578b03-ff99-40a0-9313-02085d248038	78a775c5-9a24-4760-a370-483ebc35cd3d	Kabato Lafri + Boeuf	Spécial Kabato	2500	2	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:28:00.352874+00	\N	\N	\N	2026-10-15 11:28:00.353465+00	2026-10-15 11:28:00.353473+00
3871eedc-4799-4a67-a609-01da2ea02095	ee578b03-ff99-40a0-9313-02085d248038	d1ca497d-4d17-4b6f-b7a5-37d772e72507	Tchep + Poisson	Spécial Sénégal	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:28:00.46777+00	\N	\N	\N	2026-10-15 11:28:00.468418+00	2026-10-15 11:28:00.468427+00
163291f6-3ec6-4aed-9ec2-cde110f320db	ee578b03-ff99-40a0-9313-02085d248038	c39717d7-bb67-4780-9bbe-47a00cc2f12b	Dégué	Spécial Desserts	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:28:00.58984+00	\N	\N	\N	2026-10-15 11:28:00.590624+00	2026-10-15 11:28:00.590632+00
f587ca4d-de87-494b-8884-c88a0cc4ae25	68380b5e-667a-4c22-b3b3-a4b9e0674607	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:56:40.088844+00	\N	\N	\N	2026-10-15 11:56:40.092163+00	2026-10-15 11:56:40.092171+00
1b8fe535-e9c6-4815-9008-3d8c85bd9cd8	68380b5e-667a-4c22-b3b3-a4b9e0674607	19a0e1b1-b889-4cf6-b553-017f739929aa	Couscous + Poulet	Spécial Oriental	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:56:40.280571+00	\N	\N	\N	2026-10-15 11:56:40.28162+00	2026-10-15 11:56:40.281627+00
4a24926d-6840-4fa7-84eb-3b09d72a047b	04f24f74-7622-466b-b090-0f065946e004	e2551239-6d21-4a43-aac3-f435b261884e	Frites + Boeuf	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 12:00:04.068082+00	\N	\N	\N	2026-10-15 12:00:04.068768+00	2026-10-15 12:00:04.068776+00
a067553d-9435-4c8c-b85d-f7c0b88575cb	04f24f74-7622-466b-b090-0f065946e004	3b9b5a6b-329f-4622-97ec-10226e8d5116	Attiéké + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 12:00:04.299642+00	\N	\N	\N	2026-10-15 12:00:04.300276+00	2026-10-15 12:00:04.30029+00
1f7f14ae-c6b5-4b00-8ac0-5fb69cbea6d3	04f24f74-7622-466b-b090-0f065946e004	ffaae71c-9438-4299-8493-21ce4201f095	Attiéké + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 12:00:04.470565+00	\N	\N	\N	2026-10-15 12:00:04.474065+00	2026-10-15 12:00:04.474079+00
752f3cbe-7650-47f1-955a-9dc16fa28560	04f24f74-7622-466b-b090-0f065946e004	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 12:00:04.603468+00	\N	\N	\N	2026-10-15 12:00:04.604538+00	2026-10-15 12:00:04.604548+00
213b0d6a-2d11-449c-abbb-1cc1ed7caf31	04f24f74-7622-466b-b090-0f065946e004	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 12:00:04.744292+00	\N	\N	\N	2026-10-15 12:00:04.744964+00	2026-10-15 12:00:04.744971+00
76710ee7-e134-499a-a62d-4f66817077d0	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	cd5cc4d5-6a6b-45d7-9c3d-9b4d5274d955	Kabato Lafri + Tripe	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 15:14:24.049434+00	\N	\N	\N	2026-10-15 15:14:24.050132+00	2026-10-15 15:14:24.05014+00
6372bf4e-3c1b-43f8-adb3-1426565a542a	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	3b9b5a6b-329f-4622-97ec-10226e8d5116	Attiéké + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 15:14:24.258451+00	\N	\N	\N	2026-10-15 15:14:24.259335+00	2026-10-15 15:14:24.259533+00
b65f7fc1-54ee-4a17-9b55-39f24ddddb03	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	fac18978-1efd-4b64-99a7-75758a3d73c6	Attiéké + Boeuf	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 15:14:24.535352+00	\N	\N	\N	2026-10-15 15:14:24.536144+00	2026-10-15 15:14:24.53615+00
6620dead-1d26-4cc4-8f08-1c3936cb6947	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	7e2e9acc-4cb0-4222-8e04-e09402820956	Alloco + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 15:14:25.027685+00	\N	\N	\N	2026-10-15 15:14:25.028356+00	2026-10-15 15:14:25.028362+00
cad7e9d9-a760-401a-84c0-2e62e32ac343	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 15:14:25.224224+00	\N	\N	\N	2026-10-15 15:14:25.225112+00	2026-10-15 15:14:25.225119+00
f13c512f-75da-4072-8178-30fe34d48f14	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	cddb3bf8-70f8-4dfb-8bb7-1c1c80a9d3d8	Passion	Spécial Jus	1000	2	0.00	2000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 15:14:25.476082+00	\N	\N	\N	2026-10-15 15:14:25.476489+00	2026-10-15 15:14:25.476492+00
83dca401-8acc-4269-9260-ad3a9c28a80f	722b3daf-c534-4a28-96a1-c7f866dcb6e4	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 09:51:38.160098+00	\N	\N	\N	2026-10-16 09:51:38.164626+00	2026-10-16 09:51:38.164641+00
04dde75d-0a3f-49ba-9381-1794cc5942af	722b3daf-c534-4a28-96a1-c7f866dcb6e4	d1ca497d-4d17-4b6f-b7a5-37d772e72507	Tchep + Poisson	Spécial Sénégal	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 09:51:38.303372+00	\N	\N	\N	2026-10-16 09:51:38.304284+00	2026-10-16 09:51:38.304292+00
213f00dd-8b39-4ce9-b94f-7abcdcb0e2a4	722b3daf-c534-4a28-96a1-c7f866dcb6e4	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 09:51:38.423193+00	\N	\N	\N	2026-10-16 09:51:38.424112+00	2026-10-16 09:51:38.424121+00
3e7be164-b550-4bf0-acb8-086d7e054200	722b3daf-c534-4a28-96a1-c7f866dcb6e4	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 09:51:38.767293+00	\N	\N	\N	2026-10-16 09:51:38.768863+00	2026-10-16 09:51:38.768876+00
cce56a6a-7d85-4538-bbb9-ff25c3a579f2	9a9daf47-c991-4852-b474-f2d9c12f44ec	19a0e1b1-b889-4cf6-b553-017f739929aa	Couscous + Poulet	Spécial Oriental	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 09:52:22.453827+00	\N	\N	\N	2026-10-16 09:52:22.4544+00	2026-10-16 09:52:22.454405+00
33a25eb6-f42f-43d3-b1b8-c3da96afdb1a	9a9daf47-c991-4852-b474-f2d9c12f44ec	cd408593-401c-46d0-8507-624f0342f05a	Couscous + Poisson	Spécial Oriental	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 09:52:22.54571+00	\N	\N	\N	2026-10-16 09:52:22.546493+00	2026-10-16 09:52:22.5465+00
708257ab-a1d7-4b81-9095-02939ddb79a4	3caa47f0-5560-456a-830e-e0e31694dc3d	f01823cb-78e6-4174-9d72-aadfd2436a19	Kabato Lafri + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 10:05:44.120093+00	\N	\N	\N	2026-10-16 10:05:44.120661+00	2026-10-16 10:05:44.120667+00
beb9d3e0-ea5c-4e65-8613-5e9362a53a79	3caa47f0-5560-456a-830e-e0e31694dc3d	e2551239-6d21-4a43-aac3-f435b261884e	Frites + Boeuf	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 10:05:44.390414+00	\N	\N	\N	2026-10-16 10:05:44.391277+00	2026-10-16 10:05:44.391288+00
d837faaa-c425-497e-83bc-3195091bccd8	3caa47f0-5560-456a-830e-e0e31694dc3d	5890cd36-f149-4667-9aa7-03375d3a31af	Alloco + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 10:05:44.489055+00	\N	\N	\N	2026-10-16 10:05:44.489618+00	2026-10-16 10:05:44.489624+00
1a7c9cbc-4934-40b4-9397-4292d94f7814	3caa47f0-5560-456a-830e-e0e31694dc3d	dbf93f42-7b4c-4c7e-a873-10f18a2151b0	Igname frite + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 10:07:43.593378+00	\N	\N	\N	2026-10-16 10:07:43.594264+00	2026-10-16 10:07:43.594271+00
37a7886d-6dc0-4da6-92bc-427b84bdf664	e8a42cf0-5a2f-41e7-85db-4a8ba423084d	fbb74d1d-e719-4478-b4fb-df4a903e41d5	Kabato Kope + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 10:11:24.658964+00	\N	\N	\N	2026-10-16 10:11:24.659519+00	2026-10-16 10:11:24.659525+00
669e0175-dc0d-4603-b26d-1dc2cc3936cc	e8a42cf0-5a2f-41e7-85db-4a8ba423084d	f01823cb-78e6-4174-9d72-aadfd2436a19	Kabato Lafri + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-16 10:11:24.741646+00	\N	\N	\N	2026-10-16 10:11:24.742205+00	2026-10-16 10:11:24.742209+00
ec7cb34b-f9f8-4048-8ab6-3965a0dc2777	41ec42f2-0c63-4e29-9fa8-c6b043ea9669	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:16:22.02194+00	\N	\N	\N	2026-10-19 14:16:22.023579+00	2026-10-19 14:16:22.023587+00
8c408797-09fa-40ef-9fbf-ad48437aa1e5	41ec42f2-0c63-4e29-9fa8-c6b043ea9669	3b9b5a6b-329f-4622-97ec-10226e8d5116	Attiéké + Sosso	Spécial Ivoirienne	4000	2	0.00	8000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:16:22.241169+00	\N	\N	\N	2026-10-19 14:16:22.241763+00	2026-10-19 14:16:22.241769+00
9d1635ad-9141-43be-b522-24b25de88e11	41ec42f2-0c63-4e29-9fa8-c6b043ea9669	46a09e73-28f4-4df9-984a-95ac939cfe1a	Attiéké + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:16:22.33408+00	\N	\N	\N	2026-10-19 14:16:22.334762+00	2026-10-19 14:16:22.334767+00
43fa1db8-2abb-4f74-a08c-0cf4fe36602d	41ec42f2-0c63-4e29-9fa8-c6b043ea9669	07ce2e45-1d07-45f3-8512-354a71348561	Frites + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:16:22.428431+00	\N	\N	\N	2026-10-19 14:16:22.428865+00	2026-10-19 14:16:22.428868+00
5a3e9843-b8ca-40f9-bea9-f27448d3514c	3f8f8dc6-11b6-4706-9a16-5033b227f0d1	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:16:46.269419+00	\N	\N	\N	2026-10-19 14:16:46.26999+00	2026-10-19 14:16:46.269994+00
83bbb028-9262-4677-9439-8039157c6f9d	3f8f8dc6-11b6-4706-9a16-5033b227f0d1	d1ca497d-4d17-4b6f-b7a5-37d772e72507	Tchep + Poisson	Spécial Sénégal	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:16:46.374175+00	\N	\N	\N	2026-10-19 14:16:46.374797+00	2026-10-19 14:16:46.374804+00
c579f85d-e2fd-49e4-add0-1bc48725f5a5	3f8f8dc6-11b6-4706-9a16-5033b227f0d1	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:16:46.47416+00	\N	\N	\N	2026-10-19 14:16:46.474884+00	2026-10-19 14:16:46.474893+00
8c9eed27-2030-4ec1-aa14-99ba911bebc6	3f8f8dc6-11b6-4706-9a16-5033b227f0d1	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:16:46.597502+00	\N	\N	\N	2026-10-19 14:16:46.598342+00	2026-10-19 14:16:46.598348+00
0a4a791d-0c43-41af-8209-77b08537a300	234ba969-bf26-4b05-88fa-6f0de2f6664d	934dde37-9033-45e6-86ed-7cdd2215b18e	Kabato Dah + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:33:45.633322+00	\N	\N	\N	2026-10-19 14:33:45.636247+00	2026-10-19 14:33:45.636256+00
6b8624be-7805-4420-9343-6e904c4f7bef	234ba969-bf26-4b05-88fa-6f0de2f6664d	d1ca497d-4d17-4b6f-b7a5-37d772e72507	Tchep + Poisson	Spécial Sénégal	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:33:45.772075+00	\N	\N	\N	2026-10-19 14:33:45.77446+00	2026-10-19 14:33:45.774469+00
866a64d1-2be2-4b21-b65c-1e2df646e66c	234ba969-bf26-4b05-88fa-6f0de2f6664d	19a0e1b1-b889-4cf6-b553-017f739929aa	Couscous + Poulet	Spécial Oriental	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:33:45.851628+00	\N	\N	\N	2026-10-19 14:33:45.852165+00	2026-10-19 14:33:45.85217+00
04fd647a-c8df-49f9-867d-9a8ca272fed6	234ba969-bf26-4b05-88fa-6f0de2f6664d	eef3b439-112e-485e-a7b6-0d7cd40198bf	Sauce Feuille + Poulet	Spécial Sauce	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:33:45.921917+00	\N	\N	\N	2026-10-19 14:33:45.922802+00	2026-10-19 14:33:45.922812+00
9282d5d5-8d19-46ec-aaaa-1f212800c9a3	234ba969-bf26-4b05-88fa-6f0de2f6664d	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:33:45.98688+00	\N	\N	\N	2026-10-19 14:33:45.987383+00	2026-10-19 14:33:45.987388+00
82f96417-6c7b-4327-aa1c-5fadac1e96ea	82620f6e-2b11-4bc8-b541-aac6644dc809	b3b6071a-76d0-4318-ab97-4a61d8a8ba8d	Kabato Dah + Tripe	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:17.85889+00	\N	\N	\N	2026-10-19 14:34:17.85966+00	2026-10-19 14:34:17.859667+00
4e2b68e4-94ba-4107-aeb4-9f451a8ac388	82620f6e-2b11-4bc8-b541-aac6644dc809	2c470520-ac57-4c94-bc51-2e952fe1ab21	Kabato Dah + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:17.975525+00	\N	\N	\N	2026-10-19 14:34:17.976119+00	2026-10-19 14:34:17.976124+00
58349962-6094-4bbd-b533-10913532d3f3	82620f6e-2b11-4bc8-b541-aac6644dc809	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:18.260274+00	\N	\N	\N	2026-10-19 14:34:18.26065+00	2026-10-19 14:34:18.260653+00
f9d1e3e6-2304-4c7f-a39b-f9b161967b17	82620f6e-2b11-4bc8-b541-aac6644dc809	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:18.324142+00	\N	\N	\N	2026-10-19 14:34:18.324547+00	2026-10-19 14:34:18.324551+00
80b83243-1c32-4411-ac5f-42f1bc4c8c15	82620f6e-2b11-4bc8-b541-aac6644dc809	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:18.396919+00	\N	\N	\N	2026-10-19 14:34:18.397433+00	2026-10-19 14:34:18.39744+00
b26cddaa-96b3-4974-87e4-cc6c8f0fdb5d	9187a7af-42c4-4b1e-98df-51cf420ae7c0	fbb74d1d-e719-4478-b4fb-df4a903e41d5	Kabato Kope + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:29.647814+00	\N	\N	\N	2026-10-19 14:34:29.648301+00	2026-10-19 14:34:29.648307+00
22a3651f-0572-4e95-9495-950f6e805b10	9187a7af-42c4-4b1e-98df-51cf420ae7c0	2c470520-ac57-4c94-bc51-2e952fe1ab21	Kabato Dah + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:29.732803+00	\N	\N	\N	2026-10-19 14:34:29.733354+00	2026-10-19 14:34:29.73336+00
2df6412e-4597-48c0-92b7-7ee0800a879f	9187a7af-42c4-4b1e-98df-51cf420ae7c0	f8c3551b-ce83-449e-a6c1-a640f89e8e68	Kabato Kope + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:29.88855+00	\N	\N	\N	2026-10-19 14:34:29.889087+00	2026-10-19 14:34:29.88909+00
e87244f4-9d66-400c-b4e4-d4a43714643d	9187a7af-42c4-4b1e-98df-51cf420ae7c0	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:30.008992+00	\N	\N	\N	2026-10-19 14:34:30.009515+00	2026-10-19 14:34:30.009519+00
bc209e5d-104e-4948-9d51-6234faa8c9f2	f1c7d23d-fe31-429b-8723-b5582ccba29c	ba286914-b27e-4b33-980d-9e768e8b6569	Sauce Légume + Boeuf	Spécial Sauce	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:41.157174+00	\N	\N	\N	2026-10-19 14:34:41.157805+00	2026-10-19 14:34:41.157812+00
46123169-1866-41ff-8814-ec61f4c335d2	f1c7d23d-fe31-429b-8723-b5582ccba29c	8bca5777-8762-40d2-a2f4-7c437a106df1	Sauce Dah + Mouton	Spécial Sauce	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:41.297092+00	\N	\N	\N	2026-10-19 14:34:41.297892+00	2026-10-19 14:34:41.297902+00
c77a9599-7a3d-47f6-a041-6dec7c0fc134	f1c7d23d-fe31-429b-8723-b5582ccba29c	0ef25e78-4f76-4d3c-bbe5-3ae6afcb1c77	Sauce Feuille + Poisson	Spécial Sauce	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:41.396243+00	\N	\N	\N	2026-10-19 14:34:41.396608+00	2026-10-19 14:34:41.39661+00
33665a80-45bb-45e9-8223-8a0a71dc7ad6	f1c7d23d-fe31-429b-8723-b5582ccba29c	90ad3b70-6c4f-4050-a3c5-d157cd072af5	Sauce Légume + Poisson	Spécial Sauce	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:41.463555+00	\N	\N	\N	2026-10-19 14:34:41.46406+00	2026-10-19 14:34:41.464066+00
1cae931d-443b-4fe6-8912-9b6b6b2b2448	a898bc47-55b9-4ec3-a2e7-19e82a3d0552	294aaf86-b061-4edb-9d76-83f43e34ca46	Igname bouillie + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:56.673228+00	\N	\N	\N	2026-10-19 14:34:56.673992+00	2026-10-19 14:34:56.674205+00
51503f33-18b5-4c32-b1bc-d3b199f20aaf	a898bc47-55b9-4ec3-a2e7-19e82a3d0552	3b9b5a6b-329f-4622-97ec-10226e8d5116	Attiéké + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:56.791134+00	\N	\N	\N	2026-10-19 14:34:56.791591+00	2026-10-19 14:34:56.791594+00
de0ced94-da04-4435-8d64-c152c6c51501	a898bc47-55b9-4ec3-a2e7-19e82a3d0552	fae9bc78-c632-44ec-a196-9e9f7f970fa0	Igname bouillie + Sosso	Spécial Ivoirienne	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:56.915602+00	\N	\N	\N	2026-10-19 14:34:56.916168+00	2026-10-19 14:34:56.916172+00
d6ab7a35-644f-43bc-8dbf-22e54c560183	a898bc47-55b9-4ec3-a2e7-19e82a3d0552	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	4	0.00	2000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:34:56.994054+00	\N	\N	\N	2026-10-19 14:34:56.994511+00	2026-10-19 14:34:56.994516+00
a92d24c7-d36a-42c6-85e4-2b2d009b45e8	0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c	19a0e1b1-b889-4cf6-b553-017f739929aa	Couscous + Poulet	Spécial Oriental	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:13.445284+00	\N	\N	\N	2026-10-19 14:35:13.445934+00	2026-10-19 14:35:13.445943+00
ce4b412b-bb66-4375-b20e-22162f259ba7	0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c	e2028931-16ad-47cd-a58c-03359d67788d	Couscous + Mouton	Spécial Oriental	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:13.615215+00	\N	\N	\N	2026-10-19 14:35:13.615738+00	2026-10-19 14:35:13.615743+00
de4360df-4871-4dd9-b2d8-cb3a55dd40ab	0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	3	0.00	1500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:13.74407+00	\N	\N	\N	2026-10-19 14:35:13.744931+00	2026-10-19 14:35:13.744942+00
16f74585-dba3-45e7-9e07-447b4a0fda11	e7997130-0ca2-4611-9a0f-547906350cfc	cd5cc4d5-6a6b-45d7-9c3d-9b4d5274d955	Kabato Lafri + Tripe	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:38.346389+00	\N	\N	\N	2026-10-19 14:35:38.346874+00	2026-10-19 14:35:38.346883+00
2f76b8fc-a269-4c37-ab2f-1241d47303dd	e7997130-0ca2-4611-9a0f-547906350cfc	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	Salade Panachée + Sosso	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:38.458265+00	\N	\N	\N	2026-10-19 14:35:38.458796+00	2026-10-19 14:35:38.458801+00
aa42d526-b039-486f-8474-f821cd4cb4f8	e7997130-0ca2-4611-9a0f-547906350cfc	4fa1d747-7bc0-4ec1-b54e-371169717ec3	Salade Panachée + Poisson braisé	Spécial Salade	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:38.564916+00	\N	\N	\N	2026-10-19 14:35:38.565365+00	2026-10-19 14:35:38.565369+00
58757248-c95c-4fee-b357-23616f2ae02a	dec8e488-1dc9-48fc-a597-47ca3a193e10	c39717d7-bb67-4780-9bbe-47a00cc2f12b	Dégué	Spécial Desserts	1000	1	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:50.693543+00	\N	\N	\N	2026-10-19 14:35:50.694161+00	2026-10-19 14:35:50.694169+00
70cbf674-334f-438f-8a06-6e7fbb45a3c1	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	19a0e1b1-b889-4cf6-b553-017f739929aa	Couscous + Poulet	Spécial Oriental	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:19.299348+00	\N	\N	\N	2026-10-19 14:36:19.299814+00	2026-10-19 14:36:19.299818+00
6417888b-7b85-4cba-a757-f11e671b4b48	e7997130-0ca2-4611-9a0f-547906350cfc	edc21662-09f3-4f30-acb3-714a69cac870	Igname bouillie + Poisson braisé	Spécial Ivoirienne	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:38.634945+00	\N	\N	\N	2026-10-19 14:35:38.635538+00	2026-10-19 14:35:38.635544+00
67947b4f-72d5-4161-b9df-12d42bb30188	6138d6a8-6f96-47ed-b093-baf0cfb04fa8	f1e3cc01-c0cd-4013-b667-504db4e7e954	Petit pois + Sosso	Spécial Ivoirienne	4500	1	0.00	4500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:04.053901+00	\N	\N	\N	2026-10-19 14:36:04.0546+00	2026-10-19 14:36:04.05461+00
fe6387e1-2fbe-4c67-8b09-3abed1548a19	e7997130-0ca2-4611-9a0f-547906350cfc	dbf93f42-7b4c-4c7e-a873-10f18a2151b0	Igname frite + Mouton	Spécial Ivoirienne	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:38.720173+00	\N	\N	\N	2026-10-19 14:35:38.720567+00	2026-10-19 14:35:38.72057+00
0d908938-0dfa-460c-9d76-4a581df9a2f8	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	4fa1d747-7bc0-4ec1-b54e-371169717ec3	Salade Panachée + Poisson braisé	Spécial Salade	5000	1	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:19.599008+00	\N	\N	\N	2026-10-19 14:36:19.599573+00	2026-10-19 14:36:19.599578+00
480ca1f0-9063-4c5b-850c-fcfb00852c18	8c1faad9-c719-4e21-bd8b-e3db15751754	d1ca497d-4d17-4b6f-b7a5-37d772e72507	Tchep + Poisson	Spécial Sénégal	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:37:04.519522+00	\N	\N	\N	2026-10-19 14:37:04.520055+00	2026-10-19 14:37:04.520061+00
86a5ee86-001a-44f7-8a63-6f8d0d855fcd	8c1faad9-c719-4e21-bd8b-e3db15751754	3cc363fc-99c1-4779-806b-e6d10019e507	Yassa + Boeuf	Spécial Sénégal	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:37:04.705267+00	\N	\N	\N	2026-10-19 14:37:04.705874+00	2026-10-19 14:37:04.705881+00
8e089f05-4650-4ecf-bb28-bf72020f998b	e7997130-0ca2-4611-9a0f-547906350cfc	8f8e2e8f-4b60-42d7-8ffc-c20e3b1f4690	Salade de fruits	Spécial Desserts	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:38.806276+00	\N	\N	\N	2026-10-19 14:35:38.806822+00	2026-10-19 14:35:38.80683+00
365427b5-2558-4c3a-979e-ceb00811a8b9	dec8e488-1dc9-48fc-a597-47ca3a193e10	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:50.445547+00	\N	\N	\N	2026-10-19 14:35:50.446071+00	2026-10-19 14:35:50.446075+00
36cb1c85-b2bb-4c4a-878a-e22057ece53e	dec8e488-1dc9-48fc-a597-47ca3a193e10	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:35:50.57391+00	\N	\N	\N	2026-10-19 14:35:50.574518+00	2026-10-19 14:35:50.574525+00
9f2d63c8-0494-421c-aabc-6b8a07746d65	6138d6a8-6f96-47ed-b093-baf0cfb04fa8	1dcc3350-2fdb-4653-a60f-ec1212bb682e	Alloco + Poulet	Spécial Ivoirienne	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:03.893616+00	\N	\N	\N	2026-10-19 14:36:03.894397+00	2026-10-19 14:36:03.894404+00
f9ee0394-5536-4a4e-9cfc-5796ae15686b	6138d6a8-6f96-47ed-b093-baf0cfb04fa8	6417f382-7e3a-4884-a852-bc06176f6848	Tchep + Poulet	Spécial Sénégal	2500	2	0.00	5000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:04.166097+00	\N	\N	\N	2026-10-19 14:36:04.166592+00	2026-10-19 14:36:04.166597+00
4c044de5-4661-41df-bd90-eaa0077eac9a	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	934dde37-9033-45e6-86ed-7cdd2215b18e	Kabato Dah + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:19.107928+00	\N	\N	\N	2026-10-19 14:36:19.108373+00	2026-10-19 14:36:19.108377+00
53ad068b-a728-4abb-82cc-10d4a86684f5	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	Salade Panachée + Sosso	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:19.513321+00	\N	\N	\N	2026-10-19 14:36:19.513798+00	2026-10-19 14:36:19.513802+00
062efe63-f363-4243-947e-c04475759760	8c1faad9-c719-4e21-bd8b-e3db15751754	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:37:04.601523+00	\N	\N	\N	2026-10-19 14:37:04.602063+00	2026-10-19 14:37:04.602067+00
996bb8ed-319b-4908-b66f-3b1ee2aa83bf	8c1faad9-c719-4e21-bd8b-e3db15751754	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:37:04.786116+00	\N	\N	\N	2026-10-19 14:37:04.786594+00	2026-10-19 14:37:04.786599+00
8636e7b1-3422-4fb7-a9cf-56669892503b	4630958e-a91c-426c-8d21-13cc50daf48c	6d9aee30-24bf-4df9-a616-ada6c53c4043	Bissap	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:43:24.059803+00	\N	\N	\N	2026-10-19 14:43:24.060267+00	2026-10-19 14:43:24.060271+00
e88b711f-304b-45c0-9100-09b826c1f6a6	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	f8c3551b-ce83-449e-a6c1-a640f89e8e68	Kabato Kope + Poisson	Spécial Kabato	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:19.189759+00	\N	\N	\N	2026-10-19 14:36:19.190225+00	2026-10-19 14:36:19.190227+00
8ab33d9a-642e-4fbb-8003-9aab6ff68a26	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	cd408593-401c-46d0-8507-624f0342f05a	Couscous + Poisson	Spécial Oriental	3000	1	0.00	3000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:36:19.430565+00	\N	\N	\N	2026-10-19 14:36:19.431208+00	2026-10-19 14:36:19.431215+00
b7125df5-8a1c-4068-be73-252499a54347	4630958e-a91c-426c-8d21-13cc50daf48c	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	Salade Panachée + Sosso	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-19 14:43:23.959685+00	\N	\N	\N	2026-10-19 14:43:23.960091+00	2026-10-19 14:43:23.960095+00
aca05917-ddde-47f0-99ae-a66f3d4a5c00	cfdf234b-e450-4b8d-a49a-863dc774908e	934dde37-9033-45e6-86ed-7cdd2215b18e	Kabato Dah + Poulet	Spécial Kabato	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-20 11:31:28.529901+00	\N	\N	\N	2026-10-20 11:31:28.534635+00	2026-10-20 11:31:28.534645+00
c17213e9-2f5a-4bed-accc-16c49fb91d85	cfdf234b-e450-4b8d-a49a-863dc774908e	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	Tchep + Mouton	Spécial Sénégal	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-20 11:31:28.674912+00	\N	\N	\N	2026-10-20 11:31:28.675513+00	2026-10-20 11:31:28.675518+00
62ffcec9-2dee-454e-8632-b26a0f373f47	355aa3fe-84db-4a21-8310-a24e00d52726	6417f382-7e3a-4884-a852-bc06176f6848	Tchep + Poulet	Spécial Sénégal	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-20 11:31:55.010963+00	\N	\N	\N	2026-10-20 11:31:55.011683+00	2026-10-20 11:31:55.011692+00
2e80f04f-2f6f-4279-b053-48dcdf8b7e66	355aa3fe-84db-4a21-8310-a24e00d52726	26eb12b5-a751-40b0-a6a2-6935fe010159	Tamarin	Spécial Jus	500	2	0.00	1000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-20 11:31:55.10638+00	\N	\N	\N	2026-10-20 11:31:55.107232+00	2026-10-20 11:31:55.107242+00
560b9dd9-c883-4328-aeb8-26747f369ea8	c259aa5a-5c56-48e4-af2d-2cd301af43d8	da7a9d7b-64d7-46e9-9a66-fb411d1976e5	Salade Panachée + Poulet	Spécial Salade	2500	1	0.00	2500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22 19:01:35.435736+00	\N	\N	\N	2026-10-22 19:01:35.439414+00	2026-10-22 19:01:35.439424+00
e5045925-ac9d-483b-b04c-b25422fd2a1d	c259aa5a-5c56-48e4-af2d-2cd301af43d8	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	Salade Panachée + Sosso	Spécial Salade	4000	1	0.00	4000	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22 19:01:35.627262+00	\N	\N	\N	2026-10-22 19:01:35.628399+00	2026-10-22 19:01:35.628409+00
088e8d7e-74e3-4e9a-8336-71bc26eb87d6	c259aa5a-5c56-48e4-af2d-2cd301af43d8	60621b43-1544-48ec-ac29-4b90c955c8da	Jus de citron	Jus	500	1	0.00	500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22 19:01:35.723591+00	\N	\N	\N	2026-10-22 19:01:35.724263+00	2026-10-22 19:01:35.72427+00
79bb649e-ad5c-4cfe-be65-85b53215f00e	9d70470c-a448-4666-8a3b-26a894e407ad	01dbc122-a427-4ddb-ac94-6281b3301c7e	Foufou/foutou faux brochet	Foufou / foutou	3500	1	0.00	3500	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22 19:10:39.571963+00	\N	\N	\N	2026-10-22 19:10:39.57316+00	2026-10-22 19:10:39.573184+00
\.


--
-- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.orders (id, order_number, cash_session_id, table_id, status, opened_by_user_id, closed_by_user_id, guests_count, total_ttc_xof, total_ht_xof, total_vat_xof, paid_xof, due_xof, cancelled_reason, cancelled_by_user_id, cancelled_at, opened_at, paid_at, created_at, updated_at, note_label) FROM stdin;
db5be098-d0bf-42f8-91e8-9a1ecd858825	2026-10-08-0007	bec954fb-ce8e-4e82-b546-abecd853d1ac	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	9000	9000	0	9000	0	\N	\N	\N	2026-10-08 14:43:08.38454+00	2026-10-08 14:43:57.532555+00	2026-10-08 14:43:08.390705+00	2026-10-08 14:43:57.576269+00	\N
5c853bf0-1866-4f88-a27d-f1fb5caca8f6	2026-10-06-0006	61245d2f-8301-4acc-a965-12f74778b946	6cf24b95-3c1e-473d-bdd8-2f22c321b558	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	14500	14500	0	14500	0	\N	\N	\N	2026-10-06 14:31:30.763488+00	2026-10-06 15:38:05.468575+00	2026-10-06 14:31:30.764696+00	2026-10-06 15:38:05.483179+00	\N
1ae79c99-2c11-40f4-9b4e-6948b5256aed	2026-10-08-0005	bec954fb-ce8e-4e82-b546-abecd853d1ac	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	17500	17500	0	17500	0	\N	\N	\N	2026-10-08 14:36:02.129229+00	2026-10-08 14:46:11.937599+00	2026-10-08 14:36:02.130361+00	2026-10-08 14:46:11.964467+00	\N
70e4726f-ac39-499c-9e84-97f3ccd8b1d1	2026-10-13-0003	534d40ba-7ee4-47ac-93a0-080192232503	d3602f9e-0bc4-4386-8e39-367925cb190a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	14000	14000	0	14000	0	\N	\N	\N	2026-10-13 11:29:47.516897+00	2026-10-13 12:23:48.019477+00	2026-10-13 11:29:47.517578+00	2026-10-13 12:23:48.02847+00	\N
9a9fc6d5-9fb0-4031-929e-50035995d1db	2026-10-08-0008	bec954fb-ce8e-4e82-b546-abecd853d1ac	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	3500	3500	0	3500	0	\N	\N	\N	2026-10-08 15:04:46.44191+00	2026-10-08 15:06:00.318129+00	2026-10-08 15:04:46.444438+00	2026-10-08 15:06:00.336694+00	\N
867b6c58-13d3-4af8-8f2e-094ae7f69f2c	2026-10-08-0009	bec954fb-ce8e-4e82-b546-abecd853d1ac	d3602f9e-0bc4-4386-8e39-367925cb190a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	2500	2500	0	2500	0	\N	\N	\N	2026-10-08 15:05:17.655311+00	2026-10-08 15:06:40.982486+00	2026-10-08 15:05:17.65605+00	2026-10-08 15:06:41.002953+00	\N
076109cb-177f-408e-b8d2-1a2ca7c82b9b	2026-10-08-0006	bec954fb-ce8e-4e82-b546-abecd853d1ac	6cf24b95-3c1e-473d-bdd8-2f22c321b558	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	17000	17000	0	17000	0	\N	\N	\N	2026-10-08 14:37:16.000094+00	2026-10-08 15:07:18.258182+00	2026-10-08 14:37:16.000993+00	2026-10-08 15:07:18.285248+00	\N
e6ff5588-1a97-409f-b651-8dcd1ec5135b	2026-10-08-0004	bec954fb-ce8e-4e82-b546-abecd853d1ac	830e098a-77ec-4022-8736-ed94c5fe3cfe	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	11500	11500	0	11500	0	\N	\N	\N	2026-10-08 14:33:50.550919+00	2026-10-08 15:13:44.303165+00	2026-10-08 14:33:50.598491+00	2026-10-08 15:13:44.315522+00	\N
1d99a39f-4263-4b0f-b6dd-6544080aab4a	2026-10-14-0001	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	47e6e141-b494-4813-8c9c-3c455c91a422	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	9500	9500	0	9500	0	\N	\N	\N	2026-10-14 15:18:58.014794+00	2026-10-14 16:56:02.055806+00	2026-10-14 15:18:58.019411+00	2026-10-14 16:56:02.073034+00	\N
c7b4ce76-37d6-4963-83b6-5da7c270aa02	2026-10-13-0002	534d40ba-7ee4-47ac-93a0-080192232503	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	10000	10000	0	10000	0	\N	\N	\N	2026-10-13 11:29:12.939279+00	2026-10-13 12:20:40.737877+00	2026-10-13 11:29:12.943927+00	2026-10-13 12:20:40.805343+00	\N
39bd2f25-6504-419b-b010-af921b9e733a	2026-10-13-0001	534d40ba-7ee4-47ac-93a0-080192232503	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	7500	7500	0	7500	0	\N	\N	\N	2026-10-13 11:09:31.125834+00	2026-10-13 12:22:25.158964+00	2026-10-13 11:09:31.130805+00	2026-10-13 12:22:25.173967+00	\N
ea858ea2-6771-49c3-b09b-253f7cadb4e4	2026-10-13-0005	534d40ba-7ee4-47ac-93a0-080192232503	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	9000	9000	0	9000	0	\N	\N	\N	2026-10-13 14:51:34.396067+00	2026-10-13 14:54:35.422785+00	2026-10-13 14:51:34.396932+00	2026-10-13 14:54:35.434773+00	\N
e39da534-1326-47b7-a6e2-b3bdccfbd904	2026-10-13-0004	534d40ba-7ee4-47ac-93a0-080192232503	6cf24b95-3c1e-473d-bdd8-2f22c321b558	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	6000	6000	0	6000	0	\N	\N	\N	2026-10-13 14:51:09.335621+00	2026-10-13 14:56:01.264211+00	2026-10-13 14:51:09.345587+00	2026-10-13 14:56:01.27303+00	\N
998f84b2-586b-47c9-98ce-bcd1becca088	2026-10-14-0002	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	13000	13000	0	13000	0	\N	\N	\N	2026-10-14 15:20:43.25657+00	2026-10-14 15:23:46.965129+00	2026-10-14 15:20:43.257559+00	2026-10-14 15:23:47.004583+00	\N
4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8	2026-10-14-0003	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	2500	2500	0	2500	0	\N	\N	\N	2026-10-14 15:25:09.898792+00	2026-10-14 16:55:33.508203+00	2026-10-14 15:25:09.899986+00	2026-10-14 16:55:33.516598+00	\N
ce2dd852-2947-4e23-b62e-4d8df1a69490	2026-10-14-0004	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	3500	3500	0	3500	0	\N	\N	\N	2026-10-14 15:32:31.411567+00	2026-10-14 15:35:30.273689+00	2026-10-14 15:32:31.412636+00	2026-10-14 15:35:30.292666+00	\N
b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	2026-10-06-0003	61245d2f-8301-4acc-a965-12f74778b946	f3904853-0688-4341-9830-a0a9716161bc	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	13500	13500	0	13500	0	\N	\N	\N	2026-10-06 11:29:23.368635+00	2026-10-06 11:30:12.659929+00	2026-10-06 11:29:23.370143+00	2026-10-06 11:30:12.698412+00	\N
4dca0121-6712-4315-8098-c7cb86dad49d	2026-10-06-0002	61245d2f-8301-4acc-a965-12f74778b946	6cf24b95-3c1e-473d-bdd8-2f22c321b558	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	7000	7000	0	7000	0	\N	\N	\N	2026-10-06 11:28:45.516673+00	2026-10-06 11:53:49.369116+00	2026-10-06 11:28:45.518094+00	2026-10-06 11:53:49.384752+00	\N
c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd	2026-10-06-0004	61245d2f-8301-4acc-a965-12f74778b946	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	15500	15500	0	15500	0	\N	\N	\N	2026-10-06 12:02:40.653595+00	2026-10-06 14:28:45.404554+00	2026-10-06 12:02:40.657548+00	2026-10-06 14:28:45.417074+00	\N
1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	2026-10-06-0007	61245d2f-8301-4acc-a965-12f74778b946	05aa9ad5-594d-4926-8d1a-508eec179caf	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	17500	17500	0	17500	0	\N	\N	\N	2026-10-06 14:32:06.417174+00	2026-10-06 14:40:00.033069+00	2026-10-06 14:32:06.41865+00	2026-10-06 14:40:00.103702+00	\N
64526137-92a1-418d-9d03-6393030d1f1f	2026-10-06-0008	61245d2f-8301-4acc-a965-12f74778b946	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	9500	9500	0	9500	0	\N	\N	\N	2026-10-06 14:33:57.594974+00	2026-10-06 15:08:57.831401+00	2026-10-06 14:33:57.596028+00	2026-10-06 15:08:57.874893+00	\N
b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	2026-10-06-0005	61245d2f-8301-4acc-a965-12f74778b946	cb2c0d43-facf-4ddc-bda4-b99afa2ec289	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	14500	14500	0	14500	0	\N	\N	\N	2026-10-06 14:30:35.199364+00	2026-10-06 15:10:00.990923+00	2026-10-06 14:30:35.200409+00	2026-10-06 15:10:01.021304+00	\N
c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a	2026-10-08-0002	bec954fb-ce8e-4e82-b546-abecd853d1ac	05aa9ad5-594d-4926-8d1a-508eec179caf	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	8000	8000	0	8000	0	\N	\N	\N	2026-10-08 10:47:29.00794+00	2026-10-08 10:47:48.825431+00	2026-10-08 10:47:29.00911+00	2026-10-08 10:47:48.848092+00	\N
0518ad5e-03a6-4c5a-9636-b9d33da54b4d	2026-10-06-0001	61245d2f-8301-4acc-a965-12f74778b946	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	15500	15500	0	15500	0	\N	\N	\N	2026-10-06 11:28:02.511536+00	2026-10-06 15:36:21.704651+00	2026-10-06 11:28:02.51417+00	2026-10-06 15:36:21.735706+00	\N
21a1947c-5da6-4a14-ae3f-a931b866bb53	2026-10-08-0003	bec954fb-ce8e-4e82-b546-abecd853d1ac	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	8000	8000	0	8000	0	\N	\N	\N	2026-10-08 10:50:30.015133+00	2026-10-08 11:16:20.64733+00	2026-10-08 10:50:30.015888+00	2026-10-08 11:16:20.782318+00	\N
9afbd9f2-da0c-4f3e-b309-fd0681fab463	2026-10-15-0003	0e8d76cb-c7be-43a9-9975-18ecfb230858	17c3433b-b05c-4e93-9b13-56834f10ea3a	CANCELLED	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	\N	1	0	0	0	0	0	Test nettoyage	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-15 11:26:52.720726+00	2026-10-15 11:26:42.5822+00	\N	2026-10-15 11:26:42.585119+00	2026-10-15 11:26:52.725089+00	Note 3
778a91c8-9cce-44e7-91b9-e5ff90fd0a23	2026-10-15-0006	0e8d76cb-c7be-43a9-9975-18ecfb230858	259ae2af-e711-442b-a6c7-1de4b25711ba	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	16000	16000	0	16000	0	\N	\N	\N	2026-10-15 15:14:23.936809+00	2026-10-15 16:41:08.899915+00	2026-10-15 15:14:23.937455+00	2026-10-15 16:41:08.93332+00	Note 1
f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	2026-10-15-0001	0e8d76cb-c7be-43a9-9975-18ecfb230858	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	18500	18500	0	18500	0	\N	\N	\N	2026-10-15 11:08:43.73693+00	2026-10-15 11:51:47.739641+00	2026-10-15 11:08:43.745297+00	2026-10-15 11:51:47.8114+00	Note 1
ee578b03-ff99-40a0-9313-02085d248038	2026-10-15-0002	0e8d76cb-c7be-43a9-9975-18ecfb230858	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	695652d7-7ab3-4b5d-a001-d4096cb849a0	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	11500	11500	0	11500	0	\N	\N	\N	2026-10-15 11:24:37.7422+00	2026-10-15 11:52:47.113681+00	2026-10-15 11:24:37.744466+00	2026-10-15 11:52:47.134129+00	Note 2
b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	2026-10-19-0012	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	d3602f9e-0bc4-4386-8e39-367925cb190a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	20000	20000	0	20000	0	\N	\N	\N	2026-10-19 14:36:19.034328+00	2026-10-19 14:45:32.342682+00	2026-10-19 14:36:19.035269+00	2026-10-19 14:45:32.355686+00	Note 1
9a9daf47-c991-4852-b474-f2d9c12f44ec	2026-10-15-0008	0e8d76cb-c7be-43a9-9975-18ecfb230858	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	5500	5500	0	5500	0	\N	\N	\N	2026-10-16 09:52:11.066903+00	2026-10-16 09:55:45.692972+00	2026-10-16 09:52:11.067737+00	2026-10-16 09:55:45.753713+00	Note 2
722b3daf-c534-4a28-96a1-c7f866dcb6e4	2026-10-15-0007	0e8d76cb-c7be-43a9-9975-18ecfb230858	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	7500	7500	0	7500	0	\N	\N	\N	2026-10-16 09:51:38.0422+00	2026-10-16 10:02:00.278516+00	2026-10-16 09:51:38.049555+00	2026-10-16 10:02:00.298193+00	Note 1
04f24f74-7622-466b-b090-0f065946e004	2026-10-15-0005	0e8d76cb-c7be-43a9-9975-18ecfb230858	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	13500	13500	0	13500	0	\N	\N	\N	2026-10-15 12:00:03.943424+00	2026-10-15 12:14:45.320311+00	2026-10-15 12:00:03.946874+00	2026-10-15 12:14:45.342592+00	\N
68380b5e-667a-4c22-b3b3-a4b9e0674607	2026-10-15-0004	0e8d76cb-c7be-43a9-9975-18ecfb230858	47e6e141-b494-4813-8c9c-3c455c91a422	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	3000	3000	0	3000	0	\N	\N	\N	2026-10-15 11:56:39.935521+00	2026-10-15 15:12:03.316782+00	2026-10-15 11:56:39.942445+00	2026-10-15 15:12:03.414178+00	Note 1
234ba969-bf26-4b05-88fa-6f0de2f6664d	2026-10-19-0003	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	05aa9ad5-594d-4926-8d1a-508eec179caf	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	11000	11000	0	11000	0	\N	\N	\N	2026-10-19 14:33:45.515016+00	2026-10-19 14:45:04.41685+00	2026-10-19 14:33:45.519897+00	2026-10-19 14:45:04.430145+00	Note 1
0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c	2026-10-19-0008	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	259ae2af-e711-442b-a6c7-1de4b25711ba	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	7500	7500	0	7500	0	\N	\N	\N	2026-10-19 14:35:13.3408+00	2026-10-19 14:53:05.763749+00	2026-10-19 14:35:13.341749+00	2026-10-19 14:53:05.771831+00	Note 1
6138d6a8-6f96-47ed-b093-baf0cfb04fa8	2026-10-19-0011	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	f3904853-0688-4341-9830-a0a9716161bc	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	12000	12000	0	12000	0	\N	\N	\N	2026-10-19 14:36:03.771689+00	2026-10-19 14:46:12.342809+00	2026-10-19 14:36:03.772529+00	2026-10-19 14:46:12.35139+00	Note 1
3f8f8dc6-11b6-4706-9a16-5033b227f0d1	2026-10-19-0002	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	7500	7500	0	7500	0	\N	\N	\N	2026-10-19 14:16:46.18119+00	2026-10-19 14:20:52.387554+00	2026-10-19 14:16:46.181905+00	2026-10-19 14:20:52.435645+00	\N
41ec42f2-0c63-4e29-9fa8-c6b043ea9669	2026-10-19-0001	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	cb2c0d43-facf-4ddc-bda4-b99afa2ec289	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	15000	15000	0	15000	0	\N	\N	\N	2026-10-19 14:16:21.884518+00	2026-10-19 14:22:39.565908+00	2026-10-19 14:16:21.886226+00	2026-10-19 14:22:39.576412+00	Note 1
e8a42cf0-5a2f-41e7-85db-4a8ba423084d	2026-10-15-0010	0e8d76cb-c7be-43a9-9975-18ecfb230858	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	5500	5500	0	5500	0	\N	\N	\N	2026-10-16 10:11:24.568971+00	2026-10-16 10:25:56.595189+00	2026-10-16 10:11:24.569894+00	2026-10-16 10:25:56.615121+00	\N
3caa47f0-5560-456a-830e-e0e31694dc3d	2026-10-15-0009	0e8d76cb-c7be-43a9-9975-18ecfb230858	6cf24b95-3c1e-473d-bdd8-2f22c321b558	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	12500	12500	0	12500	0	\N	\N	\N	2026-10-16 10:05:44.024591+00	2026-10-16 10:26:17.609008+00	2026-10-16 10:05:44.025489+00	2026-10-16 10:26:17.62617+00	Note 1
4630958e-a91c-426c-8d21-13cc50daf48c	2026-10-19-0014	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	259ae2af-e711-442b-a6c7-1de4b25711ba	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	5000	5000	0	5000	0	\N	\N	\N	2026-10-19 14:43:09.639256+00	2026-10-19 14:53:52.277815+00	2026-10-19 14:43:09.639763+00	2026-10-19 14:53:52.282202+00	Note 2
f1c7d23d-fe31-429b-8723-b5582ccba29c	2026-10-19-0006	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	47e6e141-b494-4813-8c9c-3c455c91a422	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	12000	12000	0	12000	0	\N	\N	\N	2026-10-19 14:34:41.076809+00	2026-10-19 14:51:28.649982+00	2026-10-19 14:34:41.077342+00	2026-10-19 14:51:28.661952+00	Note 1
82620f6e-2b11-4bc8-b541-aac6644dc809	2026-10-19-0004	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	cb2c0d43-facf-4ddc-bda4-b99afa2ec289	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	10000	10000	0	10000	0	\N	\N	\N	2026-10-19 14:34:17.762722+00	2026-10-19 14:44:26.375221+00	2026-10-19 14:34:17.763513+00	2026-10-19 14:44:26.384516+00	Note 1
e7997130-0ca2-4611-9a0f-547906350cfc	2026-10-19-0009	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	083e37af-15ee-44be-9b2e-21eef62593fc	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	20500	20500	0	20500	0	\N	\N	\N	2026-10-19 14:35:38.271866+00	2026-10-19 14:41:29.600401+00	2026-10-19 14:35:38.272555+00	2026-10-19 14:41:29.621713+00	Note 1
9187a7af-42c4-4b1e-98df-51cf420ae7c0	2026-10-19-0005	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	9000	9000	0	9000	0	\N	\N	\N	2026-10-19 14:34:29.566891+00	2026-10-19 14:47:33.415087+00	2026-10-19 14:34:29.567729+00	2026-10-19 14:47:33.426525+00	Note 1
8c1faad9-c719-4e21-bd8b-e3db15751754	2026-10-19-0013	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	\N	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	10000	10000	0	10000	0	\N	\N	\N	2026-10-19 14:37:04.415052+00	2026-10-19 14:42:39.19257+00	2026-10-19 14:37:04.41565+00	2026-10-19 14:42:39.201821+00	\N
dec8e488-1dc9-48fc-a597-47ca3a193e10	2026-10-19-0010	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	6cf24b95-3c1e-473d-bdd8-2f22c321b558	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	2000	2000	0	2000	0	\N	\N	\N	2026-10-19 14:35:50.361359+00	2026-10-19 14:44:09.554551+00	2026-10-19 14:35:50.361835+00	2026-10-19 14:44:09.55995+00	Note 1
a898bc47-55b9-4ec3-a2e7-19e82a3d0552	2026-10-19-0007	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	830e098a-77ec-4022-8736-ed94c5fe3cfe	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	13500	13500	0	13500	0	\N	\N	\N	2026-10-19 14:34:56.584258+00	2026-10-19 14:39:11.0163+00	2026-10-19 14:34:56.585018+00	2026-10-19 14:39:11.030374+00	Note 1
355aa3fe-84db-4a21-8310-a24e00d52726	2026-10-20-0002	a47b2f40-5c96-4b9e-9269-d673c78b5a50	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	3500	3500	0	3500	0	\N	\N	\N	2026-10-20 11:31:45.437404+00	2026-10-20 16:41:50.261343+00	2026-10-20 11:31:45.438701+00	2026-10-20 16:41:50.289582+00	Note 2
cfdf234b-e450-4b8d-a49a-863dc774908e	2026-10-20-0001	a47b2f40-5c96-4b9e-9269-d673c78b5a50	17c3433b-b05c-4e93-9b13-56834f10ea3a	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	6000	6000	0	6000	0	\N	\N	\N	2026-10-20 11:31:28.414356+00	2026-10-20 11:33:58.473451+00	2026-10-20 11:31:28.419809+00	2026-10-20 11:33:58.510581+00	Note 1
9d70470c-a448-4666-8a3b-26a894e407ad	2026-10-22-0002	cd0d53b5-fb69-40f5-bbbc-653961ec963e	cb2c0d43-facf-4ddc-bda4-b99afa2ec289	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	1	3500	3500	0	3500	0	\N	\N	\N	2026-10-22 19:02:09.394909+00	2026-10-22 19:10:58.546191+00	2026-10-22 19:02:09.395979+00	2026-10-22 19:10:58.635111+00	Note 2
c259aa5a-5c56-48e4-af2d-2cd301af43d8	2026-10-22-0001	cd0d53b5-fb69-40f5-bbbc-653961ec963e	cb2c0d43-facf-4ddc-bda4-b99afa2ec289	PAID	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	4	7000	7000	0	7000	0	\N	\N	\N	2026-10-22 19:01:35.271933+00	2026-10-22 19:11:12.231717+00	2026-10-22 19:01:35.276547+00	2026-10-22 19:11:12.29793+00	Note 1
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
b916d44e-3cc3-4656-99e0-ea6086f708a9	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	61245d2f-8301-4acc-a965-12f74778b946	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	13500	14000	500	\N	\N	CAPTURED	pay-b61f47d3-6a41-4cbb-bc0c-84fcc09036f5-1791286212581-lrcxbj9	2026-10-06 11:30:12.642293+00	2026-10-06 11:30:12.642309+00
a1634473-271f-443f-a6b0-30130d12effa	4dca0121-6712-4315-8098-c7cb86dad49d	61245d2f-8301-4acc-a965-12f74778b946	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	7000	10000	3000	\N	\N	CAPTURED	pay-4dca0121-6712-4315-8098-c7cb86dad49d-1791287629317-ikuydxj	2026-10-06 11:53:49.359877+00	2026-10-06 11:53:49.35989+00
8b700a71-4528-4588-9a29-7d4ba886e8ed	c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd	61245d2f-8301-4acc-a965-12f74778b946	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	15500	15500	0	WAVE	\N	CAPTURED	pay-c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd-1791296925355-881c8fs	2026-10-06 14:28:45.392271+00	2026-10-06 14:28:45.392285+00
dee46df9-b970-409f-bcea-1555176e82f4	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	61245d2f-8301-4acc-a965-12f74778b946	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	17500	17500	0	\N	\N	CAPTURED	pay-1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2-1791297599978-esvgr14	2026-10-06 14:40:00.023553+00	2026-10-06 14:40:00.023565+00
fccf036d-3005-4f99-870f-c6680aaf2a31	64526137-92a1-418d-9d03-6393030d1f1f	61245d2f-8301-4acc-a965-12f74778b946	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	9500	10000	500	\N	\N	CAPTURED	pay-64526137-92a1-418d-9d03-6393030d1f1f-1791299337740-nkthgc9	2026-10-06 15:08:57.81612+00	2026-10-06 15:08:57.81613+00
761b7ef5-f574-43d1-9038-bc5b0eeadcb4	b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	61245d2f-8301-4acc-a965-12f74778b946	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	14500	15000	500	\N	\N	CAPTURED	pay-b3149ccf-0f04-4a5c-8ff9-5aad99d0a137-1791299400930-2zffk0a	2026-10-06 15:10:00.97661+00	2026-10-06 15:10:00.976649+00
544d8200-4a3d-43c1-80c1-45d37ea95f5a	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	61245d2f-8301-4acc-a965-12f74778b946	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	15500	16000	500	\N	\N	CAPTURED	pay-0518ad5e-03a6-4c5a-9636-b9d33da54b4d-1791300981640-sgaiukk	2026-10-06 15:36:21.696793+00	2026-10-06 15:36:21.696801+00
2abfb1c6-924f-4ca4-b42a-828add61ceff	5c853bf0-1866-4f88-a27d-f1fb5caca8f6	61245d2f-8301-4acc-a965-12f74778b946	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	14500	15000	500	\N	\N	CAPTURED	pay-5c853bf0-1866-4f88-a27d-f1fb5caca8f6-1791301085428-xreh3d5	2026-10-06 15:38:05.460328+00	2026-10-06 15:38:05.460337+00
9053909f-a781-4609-9174-1e986810c412	c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a	bec954fb-ce8e-4e82-b546-abecd853d1ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	8000	8000	0	\N	\N	CAPTURED	pay-c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a-1791456468769-8dgt827	2026-10-08 10:47:48.818684+00	2026-10-08 10:47:48.818693+00
b86016a3-57a4-4d79-8a82-92349aad5825	21a1947c-5da6-4a14-ae3f-a931b866bb53	bec954fb-ce8e-4e82-b546-abecd853d1ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	8000	8000	0	\N	\N	CAPTURED	pay-21a1947c-5da6-4a14-ae3f-a931b866bb53-1791458180563-su99j77	2026-10-08 11:16:20.634467+00	2026-10-08 11:16:20.634476+00
91b83a0e-d8d4-48ee-9e5b-6769b4e07e39	db5be098-d0bf-42f8-91e8-9a1ecd858825	bec954fb-ce8e-4e82-b546-abecd853d1ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	9000	10000	1000	\N	\N	CAPTURED	pay-db5be098-d0bf-42f8-91e8-9a1ecd858825-1791470637450-pecq95p	2026-10-08 14:43:57.52062+00	2026-10-08 14:43:57.52063+00
6a6e1813-0825-4c8c-8a7d-06bbf91bdbea	1ae79c99-2c11-40f4-9b4e-6948b5256aed	bec954fb-ce8e-4e82-b546-abecd853d1ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	17500	20000	2500	\N	\N	CAPTURED	pay-1ae79c99-2c11-40f4-9b4e-6948b5256aed-1791470771894-3zkola6	2026-10-08 14:46:11.928568+00	2026-10-08 14:46:11.928583+00
6251cc2f-2a4b-41ad-8fb5-74ada8579abc	9a9fc6d5-9fb0-4031-929e-50035995d1db	bec954fb-ce8e-4e82-b546-abecd853d1ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	3500	3500	0	ORANGE_MONEY	\N	CAPTURED	pay-9a9fc6d5-9fb0-4031-929e-50035995d1db-1791471960257-babmt5f	2026-10-08 15:06:00.305398+00	2026-10-08 15:06:00.305407+00
0336184a-b88c-463d-9ea9-8e7cfae6fce9	867b6c58-13d3-4af8-8f2e-094ae7f69f2c	bec954fb-ce8e-4e82-b546-abecd853d1ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	2500	2500	0	MTN_MOMO	\N	CAPTURED	pay-867b6c58-13d3-4af8-8f2e-094ae7f69f2c-1791472000933-hg68foq	2026-10-08 15:06:40.974457+00	2026-10-08 15:06:40.974469+00
dfb0d182-a56c-46e8-860a-d52410f695c6	076109cb-177f-408e-b8d2-1a2ca7c82b9b	bec954fb-ce8e-4e82-b546-abecd853d1ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	17000	17000	0	WAVE	\N	CAPTURED	pay-076109cb-177f-408e-b8d2-1a2ca7c82b9b-1791472038207-ln1qvtg	2026-10-08 15:07:18.250195+00	2026-10-08 15:07:18.250202+00
f87360b3-2919-45b5-9c8f-f0d21ba4c4e1	e6ff5588-1a97-409f-b651-8dcd1ec5135b	bec954fb-ce8e-4e82-b546-abecd853d1ac	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	11500	12000	500	\N	\N	CAPTURED	pay-e6ff5588-1a97-409f-b651-8dcd1ec5135b-1791472424248-udc53x1	2026-10-08 15:13:44.293073+00	2026-10-08 15:13:44.293083+00
556b1b9f-3bad-47d0-a487-0879ec2aae3f	c7b4ce76-37d6-4963-83b6-5da7c270aa02	534d40ba-7ee4-47ac-93a0-080192232503	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	10000	10000	0	WAVE	\N	CAPTURED	pay-c7b4ce76-37d6-4963-83b6-5da7c270aa02-1791894040647-4ttw4ev	2026-10-13 12:20:40.722673+00	2026-10-13 12:20:40.722684+00
141a3d65-75fb-4489-9749-d7fcac22031b	39bd2f25-6504-419b-b010-af921b9e733a	534d40ba-7ee4-47ac-93a0-080192232503	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	7500	7500	0	ORANGE_MONEY	\N	CAPTURED	pay-39bd2f25-6504-419b-b010-af921b9e733a-1791894145110-7davtno	2026-10-13 12:22:25.149974+00	2026-10-13 12:22:25.149985+00
b53715e2-f60d-4478-8013-11270c7e0732	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	534d40ba-7ee4-47ac-93a0-080192232503	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	14000	15000	1000	\N	\N	CAPTURED	pay-70e4726f-ac39-499c-9e84-97f3ccd8b1d1-1791894227969-umwg3x2	2026-10-13 12:23:48.010176+00	2026-10-13 12:23:48.010192+00
6f69dfb8-77f9-40ea-9405-ed3cfb579320	ea858ea2-6771-49c3-b09b-253f7cadb4e4	534d40ba-7ee4-47ac-93a0-080192232503	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	9000	9000	0	MTN_MOMO	\N	CAPTURED	pay-ea858ea2-6771-49c3-b09b-253f7cadb4e4-1791903275348-20d2yih	2026-10-13 14:54:35.413387+00	2026-10-13 14:54:35.4134+00
88bb26c8-211a-450a-b8c3-372434e60909	e39da534-1326-47b7-a6e2-b3bdccfbd904	534d40ba-7ee4-47ac-93a0-080192232503	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	6000	10000	4000	\N	\N	CAPTURED	pay-e39da534-1326-47b7-a6e2-b3bdccfbd904-1791903361221-2zh6piw	2026-10-13 14:56:01.257437+00	2026-10-13 14:56:01.257452+00
cd22b82a-d706-43b3-81ef-8483095f121c	998f84b2-586b-47c9-98ce-bcd1becca088	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	13000	13000	0	\N	\N	CAPTURED	pay-998f84b2-586b-47c9-98ce-bcd1becca088-1791991426872-fxyrrl8	2026-10-14 15:23:46.949094+00	2026-10-14 15:23:46.949106+00
5678587a-33a1-4145-b03c-900dc0e8b22f	ce2dd852-2947-4e23-b62e-4d8df1a69490	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	3500	5000	1500	\N	\N	CAPTURED	pay-ce2dd852-2947-4e23-b62e-4d8df1a69490-1791992130228-dhnlowo	2026-10-14 15:35:30.265095+00	2026-10-14 15:35:30.265103+00
2d3f2a08-a6fd-4a0e-8890-e7e93a0fe81a	4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	2500	3000	500	\N	\N	CAPTURED	pay-4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8-1791996933460-age9bqn	2026-10-14 16:55:33.501692+00	2026-10-14 16:55:33.501698+00
0c5afc42-12f1-43c5-85cd-eb07feb63e08	1d99a39f-4263-4b0f-b6dd-6544080aab4a	8d79f149-6cbe-4ab7-90f7-cfb26f6a30bb	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	9500	10000	500	\N	\N	CAPTURED	pay-1d99a39f-4263-4b0f-b6dd-6544080aab4a-1791996962009-28erpo8	2026-10-14 16:56:02.047517+00	2026-10-14 16:56:02.047526+00
d487a3b5-bf6b-440d-96bb-ffaa31fc9b68	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	18500	20000	1500	\N	\N	CAPTURED	pay-f2fb511b-1bdd-4b34-8174-1b6c7ab582b0-1792065107623-uk71sg3	2026-10-15 11:51:47.715684+00	2026-10-15 11:51:47.7157+00
53738b3c-1ef5-4f0c-a620-f00af82e1bfe	ee578b03-ff99-40a0-9313-02085d248038	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	11500	11500	0	WAVE	\N	CAPTURED	pay-ee578b03-ff99-40a0-9313-02085d248038-1792065167064-1k9nbr9	2026-10-15 11:52:47.099542+00	2026-10-15 11:52:47.099551+00
f1917d71-6db8-46ac-bb8b-5e7b32711e5d	04f24f74-7622-466b-b090-0f065946e004	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	13500	15000	1500	\N	\N	CAPTURED	pay-04f24f74-7622-466b-b090-0f065946e004-1792066485256-ddgj3vn	2026-10-15 12:14:45.30052+00	2026-10-15 12:14:45.300527+00
bbe0106e-b4e8-4e46-8f4c-561066cecb13	68380b5e-667a-4c22-b3b3-a4b9e0674607	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	3000	3000	0	\N	\N	CAPTURED	pay-68380b5e-667a-4c22-b3b3-a4b9e0674607-1792077123250-74ifjcr	2026-10-15 15:12:03.304665+00	2026-10-15 15:12:03.304674+00
666975d6-7915-4b61-a067-680e8cfbb971	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	16000	16000	0	\N	\N	CAPTURED	pay-778a91c8-9cce-44e7-91b9-e5ff90fd0a23-1792082468839-gbpy8ao	2026-10-15 16:41:08.889838+00	2026-10-15 16:41:08.889845+00
22202f24-9b04-4266-a096-020dc012083b	9a9daf47-c991-4852-b474-f2d9c12f44ec	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	5500	5500	0	\N	\N	CAPTURED	pay-9a9daf47-c991-4852-b474-f2d9c12f44ec-1792144545626-gijvpiq	2026-10-16 09:55:45.679913+00	2026-10-16 09:55:45.679925+00
4f79df43-0c12-4d28-8497-1bb9122f5b5d	722b3daf-c534-4a28-96a1-c7f866dcb6e4	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	7500	7500	0	\N	\N	CAPTURED	pay-722b3daf-c534-4a28-96a1-c7f866dcb6e4-1792144920215-bi0q1ra	2026-10-16 10:02:00.27009+00	2026-10-16 10:02:00.270101+00
f1b90d2b-4330-4c41-9344-44c98e756582	e8a42cf0-5a2f-41e7-85db-4a8ba423084d	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	5500	5500	0	\N	\N	CAPTURED	pay-e8a42cf0-5a2f-41e7-85db-4a8ba423084d-1792146356516-4p8d9kz	2026-10-16 10:25:56.582465+00	2026-10-16 10:25:56.582475+00
b33e307a-1901-436c-8e95-b2a2f02f2dc7	3caa47f0-5560-456a-830e-e0e31694dc3d	0e8d76cb-c7be-43a9-9975-18ecfb230858	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	12500	12500	0	\N	\N	CAPTURED	pay-3caa47f0-5560-456a-830e-e0e31694dc3d-1792146377558-xmpjjhn	2026-10-16 10:26:17.600323+00	2026-10-16 10:26:17.600332+00
219650f5-63b9-4867-9c38-0f27414fcdc6	3f8f8dc6-11b6-4706-9a16-5033b227f0d1	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	7500	8000	500	\N	\N	CAPTURED	pay-3f8f8dc6-11b6-4706-9a16-5033b227f0d1-1792419652286-7np1zjd	2026-10-19 14:20:52.363014+00	2026-10-19 14:20:52.363044+00
89fe7d08-379c-4a4c-8d64-e4bfd7c5bb0d	41ec42f2-0c63-4e29-9fa8-c6b043ea9669	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	15000	20000	5000	\N	\N	CAPTURED	pay-41ec42f2-0c63-4e29-9fa8-c6b043ea9669-1792419759514-5yytel4	2026-10-19 14:22:39.557676+00	2026-10-19 14:22:39.557686+00
a6071376-6f80-47c5-b70e-1674bc6706e5	a898bc47-55b9-4ec3-a2e7-19e82a3d0552	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	13500	15000	1500	\N	\N	CAPTURED	pay-a898bc47-55b9-4ec3-a2e7-19e82a3d0552-1792420750971-484bz44	2026-10-19 14:39:11.009276+00	2026-10-19 14:39:11.009287+00
2114e5e1-2451-41df-9bc1-b25f7382c564	e7997130-0ca2-4611-9a0f-547906350cfc	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	20500	21000	500	\N	\N	CAPTURED	pay-e7997130-0ca2-4611-9a0f-547906350cfc-1792420889552-j73kjfc	2026-10-19 14:41:29.593625+00	2026-10-19 14:41:29.593634+00
369550f7-dbb0-496d-b9ba-0e8b2c37b701	8c1faad9-c719-4e21-bd8b-e3db15751754	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	10000	10000	0	\N	\N	CAPTURED	pay-8c1faad9-c719-4e21-bd8b-e3db15751754-1792420959163-8566tvt	2026-10-19 14:42:39.187591+00	2026-10-19 14:42:39.187597+00
3bec01b1-2954-4bb5-bb9c-9cf95068b21f	dec8e488-1dc9-48fc-a597-47ca3a193e10	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	2000	2000	0	\N	\N	CAPTURED	pay-dec8e488-1dc9-48fc-a597-47ca3a193e10-1792421049524-1bubjii	2026-10-19 14:44:09.548816+00	2026-10-19 14:44:09.548824+00
bd86f281-ceb4-46eb-a183-1f86bb0869ca	82620f6e-2b11-4bc8-b541-aac6644dc809	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	10000	10000	0	\N	\N	CAPTURED	pay-82620f6e-2b11-4bc8-b541-aac6644dc809-1792421066341-ulfq04m	2026-10-19 14:44:26.37058+00	2026-10-19 14:44:26.370586+00
395a14da-f7b8-44e4-98fd-9f527159c498	234ba969-bf26-4b05-88fa-6f0de2f6664d	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	11000	11000	0	WAVE	\N	CAPTURED	pay-234ba969-bf26-4b05-88fa-6f0de2f6664d-1792421104387-y3aruz0	2026-10-19 14:45:04.412247+00	2026-10-19 14:45:04.412253+00
564d9fcf-ffbd-4e2c-a492-e3b046174f99	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	20000	20000	0	MTN_MOMO	\N	CAPTURED	pay-b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1-1792421132312-sp80j3e	2026-10-19 14:45:32.338375+00	2026-10-19 14:45:32.338381+00
582db3ba-ce42-4d99-b3a6-914709af83b3	6138d6a8-6f96-47ed-b093-baf0cfb04fa8	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	12000	12000	0	ORANGE_MONEY	\N	CAPTURED	pay-6138d6a8-6f96-47ed-b093-baf0cfb04fa8-1792421172312-i93ipii	2026-10-19 14:46:12.337015+00	2026-10-19 14:46:12.337021+00
6fad81ff-5ef5-4f76-8d93-b3baab109246	9187a7af-42c4-4b1e-98df-51cf420ae7c0	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	MOBILE_MONEY	9000	9000	0	MOOV	\N	CAPTURED	pay-9187a7af-42c4-4b1e-98df-51cf420ae7c0-1792421253382-b7900w1	2026-10-19 14:47:33.410257+00	2026-10-19 14:47:33.410263+00
8e962b5a-1289-45e0-98f8-a11d6cdd718a	f1c7d23d-fe31-429b-8723-b5582ccba29c	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	12000	15000	3000	\N	\N	CAPTURED	pay-f1c7d23d-fe31-429b-8723-b5582ccba29c-1792421488616-om9effg	2026-10-19 14:51:28.644774+00	2026-10-19 14:51:28.64478+00
0053d599-4c29-4019-b493-c6c794434838	0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	7500	10000	2500	\N	\N	CAPTURED	pay-0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c-1792421585708-2s8t2rj	2026-10-19 14:53:05.758535+00	2026-10-19 14:53:05.758541+00
41641af7-f183-4c6e-b3a6-343c29a16a90	4630958e-a91c-426c-8d21-13cc50daf48c	0d1edc4b-da9e-4bc1-92cb-6a00b77e8381	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	5000	5000	0	\N	\N	CAPTURED	pay-4630958e-a91c-426c-8d21-13cc50daf48c-1792421632245-zo5dkhu	2026-10-19 14:53:52.272789+00	2026-10-19 14:53:52.272795+00
4c232eb6-f36a-4931-ab15-ced6028bb8c9	cfdf234b-e450-4b8d-a49a-863dc774908e	a47b2f40-5c96-4b9e-9269-d673c78b5a50	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	6000	6000	0	\N	\N	CAPTURED	pay-cfdf234b-e450-4b8d-a49a-863dc774908e-1792496038410-g09x4hh	2026-10-20 11:33:58.462003+00	2026-10-20 11:33:58.462023+00
c35cbde7-7bb8-4aac-985b-92ff31fff7e8	355aa3fe-84db-4a21-8310-a24e00d52726	a47b2f40-5c96-4b9e-9269-d673c78b5a50	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	3500	3500	0	\N	\N	CAPTURED	pay-355aa3fe-84db-4a21-8310-a24e00d52726-1792514510218-rdeyu32	2026-10-20 16:41:50.252568+00	2026-10-20 16:41:50.252577+00
0099ca67-a281-462c-8219-6f7866a594af	9d70470c-a448-4666-8a3b-26a894e407ad	cd0d53b5-fb69-40f5-bbbc-653961ec963e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	3500	3500	0	\N	\N	CAPTURED	pay-9d70470c-a448-4666-8a3b-26a894e407ad-1792696258453-h25hzfw	2026-10-22 19:10:58.526716+00	2026-10-22 19:10:58.526727+00
f242cc60-ae41-4eb8-bdc1-06a66f39c670	c259aa5a-5c56-48e4-af2d-2cd301af43d8	cd0d53b5-fb69-40f5-bbbc-653961ec963e	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	CASH	7000	7000	0	\N	\N	CAPTURED	pay-c259aa5a-5c56-48e4-af2d-2cd301af43d8-1792696272162-f8112t8	2026-10-22 19:11:12.22054+00	2026-10-22 19:11:12.220556+00
\.


--
-- Data for Name: print_jobs; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.print_jobs (id, order_id, job_type, status, content, open_drawer, cut, is_duplicate, error_message, printed_at, created_at, updated_at, claimed_at, terminal_id, attempts) FROM stdin;
fa9540be-233f-48d4-81fe-bfe91a9131e1	c8ff7858-0602-4d47-a5d6-1d7c00e7d1dd	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-06-0004\nTABLE Comptoir      Couverts : 1\nDate            06/10/2026 14:28\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Frites + Poisson brai 5 000 F\n1x Frites + Sosso        4 000 F\n1x Alloco + Poulet       2 500 F\n1x Alloco + Sosso        4 000 F\n--------------------------------\nTOTAL TTC           15 500 F CFA\n--------------------------------\nPaiement MOBILE_MONEY : 15 500 F\nRecu caissier :         15 500 F\nMonnaie rendue :             0 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	f	t	f	\N	2026-10-06 14:28:45.460464+00	2026-10-06 14:28:45.419587+00	2026-10-06 14:28:45.463723+00	\N	\N	0
2beadc3a-569c-4edb-8de3-1390de02a9f4	b61f47d3-6a41-4cbb-bc0c-84fcc09036f5	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-06-0003\nTable 6             Couverts : 4\nDate            06/10/2026 11:30\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Kope + Poisson 3 000 F\n1x Kabato Lafri + Tripe  2 500 F\n1x Salade Panachée + Sos 4 000 F\n1x Yassa + Boeuf         2 500 F\n1x Bissap                  500 F\n1x Passion               1 000 F\n--------------------------------\nTOTAL TTC           13 500 F CFA\n--------------------------------\nReglement Especes :     13 500 F\nRecu caissier :         14 000 F\nMonnaie rendue :           500 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000004       \n[QR_CODE: http://54.247.95.108/fr/verification/01a110fa-7c94-7ffe-902f-14e1a0822292]\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-06 11:30:14.51962+00	2026-10-06 11:30:14.475424+00	2026-10-06 11:30:14.525715+00	\N	\N	0
cd6d740f-1bdb-4564-babe-75a33aa65ca6	4dca0121-6712-4315-8098-c7cb86dad49d	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-06-0002\nTable 9             Couverts : 4\nDate            06/10/2026 11:53\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Sauce Feuille + Poule 2 500 F\n1x Dégué                 1 000 F\n1x Tchep + Mouton        3 500 F\n--------------------------------\nTOTAL TTC            7 000 F CFA\n--------------------------------\nReglement Especes :      7 000 F\nRecu caissier :         10 000 F\nMonnaie rendue :         3 000 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-06 11:53:49.42659+00	2026-10-06 11:53:49.388161+00	2026-10-06 11:53:49.43016+00	\N	\N	0
872cd0e1-9d6d-49b5-91ef-6f868593e3c1	1ab3b1e9-7b9e-4e99-ad05-b3611300d7e2	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-06-0007\nTable 5             Couverts : 4\nDate            06/10/2026 14:40\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Salade de fruits        500 F\n1x Frites + Poisson brai 5 000 F\n1x Frites + Poulet       2 500 F\n1x Attiéké + Mouton      3 500 F\n1x Couscous + Mouton     3 500 F\n1x Couscous + Boeuf      2 500 F\n--------------------------------\nTOTAL TTC           17 500 F CFA\n--------------------------------\nReglement Especes :     17 500 F\nRecu caissier :         17 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000006       \n[QR_CODE: http://54.247.95.108/fr/verification/01a111a8-3c83-7ffe-9031-33b7fb3511d4]\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-06 14:40:00.964482+00	2026-10-06 14:40:00.77595+00	2026-10-06 14:40:00.967779+00	\N	\N	0
096f5ca7-3e34-461f-9fb2-b93725d4fa0a	64526137-92a1-418d-9d03-6393030d1f1f	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-06-0008\nTABLE Comptoir      Couverts : 1\nDate            06/10/2026 15:08\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Yassa + Mouton        3 500 F\n1x Tchep + Mouton        3 500 F\n1x Yassa + Poulet        2 500 F\n--------------------------------\nTOTAL TTC            9 500 F CFA\n--------------------------------\nReglement Especes :      9 500 F\nRecu caissier :         10 000 F\nMonnaie rendue :           500 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-06 15:08:58.035486+00	2026-10-06 15:08:57.881541+00	2026-10-06 15:08:58.04153+00	\N	\N	0
a82af4f1-6dd6-43be-9cc7-53177624e7ab	5c853bf0-1866-4f88-a27d-f1fb5caca8f6	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-06-0006\nTable 9             Couverts : 4\nDate            06/10/2026 15:38\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Dah + Mouton   3 500 F\n1x Kabato Lafri + Boeuf  2 500 F\n1x Passion               1 000 F\n1x Yassa + Boeuf         2 500 F\n1x Salade Panachée + Poi 5 000 F\n--------------------------------\nTOTAL TTC           14 500 F CFA\n--------------------------------\nReglement Especes :     14 500 F\nRecu caissier :         15 000 F\nMonnaie rendue :           500 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-06 15:38:05.545003+00	2026-10-06 15:38:05.504145+00	2026-10-06 15:38:05.549134+00	\N	\N	0
db289b8c-5158-43c2-84ac-9dd82fe88e7c	b3149ccf-0f04-4a5c-8ff9-5aad99d0a137	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-06-0005\nTable 1             Couverts : 4\nDate            06/10/2026 15:10\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Lafri + Poisso 3 000 F\n1x Tamarin                 500 F\n1x Frites + Sosso        4 000 F\n1x Attiéké + Mouton      3 500 F\n1x Igname frite + Mouton 3 500 F\n--------------------------------\nTOTAL TTC           14 500 F CFA\n--------------------------------\nReglement Especes :     14 500 F\nRecu caissier :         15 000 F\nMonnaie rendue :           500 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-06 15:10:01.29339+00	2026-10-06 15:10:01.05531+00	2026-10-06 15:10:01.310924+00	\N	\N	0
c810324e-24e9-4f8f-8513-2453cc52f1dd	0518ad5e-03a6-4c5a-9636-b9d33da54b4d	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-06-0001\nTable 3             Couverts : 4\nDate            06/10/2026 15:36\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Frites + Poisson brai 5 000 F\n1x Salade Panachée + Boe 2 500 F\n1x Tamarin                 500 F\n1x Kabato Lafri + Boeuf  2 500 F\n1x Kabato Lafri + Boeuf  2 500 F\n1x Kabato Lafri + Boeuf  2 500 F\n--------------------------------\nTOTAL TTC           15 500 F CFA\n--------------------------------\nReglement Especes :     15 500 F\nRecu caissier :         16 000 F\nMonnaie rendue :           500 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000007       \n[QR_CODE: http://54.247.95.108/fr/verification/01a111db-d78b-7cc8-8f4c-921f1f1ba8b5]\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-06 15:36:23.070464+00	2026-10-06 15:36:22.791039+00	2026-10-06 15:36:23.074797+00	\N	\N	0
5e3d2c46-28e4-4b5f-bc07-080f494e48a9	\N	Z_REPORT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n================================\n         RAPPORT Z N* 1         \n CLOTURE DEFINITIVE & CERTIFIEE \n================================\nDate comptable        2026-10-06\nOuvert le       2026-10-06 11:07\nCloture le      2026-10-06 15:40\n--------------------------------\nTOTAL VENTES TTC       107 500 F\nTOTAL HT               107 500 F\nTVA (0% REGIME TEE)          0 F\n--------------------------------\n     VENTILATION REGLEMENTS     \nCASH                    92 000 F\nMOBILE_MONEY            15 500 F\n--------------------------------\n      VENTES PAR CATEGORIE      \nSpécial Kabato          22 000 F\nSpécial Jus              3 500 F\nSpécial Sénégal         18 000 F\nSpécial Salade          11 500 F\nSpécial Sauce            2 500 F\nSpécial Desserts         1 500 F\nSpécial Ivoirienne      42 500 F\nSpécial Oriental         6 000 F\n--------------------------------\n    BILAN ESPECES EN CAISSE     \nFond initial            50 000 F\nEspeces attendues      142 000 F\nEspeces comptees       142 000 F\nECART DE CAISSE              0 F\n================================\nCommandes : 8    Annulations : 0\n================================	f	t	f	\N	2026-10-06 15:40:40.429565+00	2026-10-06 15:40:40.388883+00	2026-10-06 15:40:40.433958+00	\N	\N	0
080ddf17-ec1e-492d-9247-79083381551a	c10e28f1-9bc1-48c1-8ddb-ea2ea4a1313a	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-08-0002\nTable 5             Couverts : 4\nDate            08/10/2026 10:47\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Couscous + Poisson    3 000 F\n1x Couscous + Mouton     3 500 F\n1x Salade de fruits        500 F\n1x Dégué                 1 000 F\n--------------------------------\nTOTAL TTC            8 000 F CFA\n--------------------------------\nReglement Especes :      8 000 F\nRecu caissier :          8 000 F\nMonnaie rendue :             0 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-08 10:47:49.096541+00	2026-10-08 10:47:48.851227+00	2026-10-08 10:47:49.099777+00	\N	\N	0
2d30f63f-5f0b-4917-8114-839de4fe2821	21a1947c-5da6-4a14-ae3f-a931b866bb53	RECEIPT	DONE	[LOGO]\n     Abidjan, Côte d'Ivoire     \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-08-0003\nTABLE Comptoir      Couverts : 1\nDate            08/10/2026 11:16\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Lafri + Poulet 2 500 F\n1x Salade de fruits        500 F\n1x Igname bouillie + Poi 5 000 F\n--------------------------------\nTOTAL TTC            8 000 F CFA\n--------------------------------\nReglement Especes :      8 000 F\nRecu caissier :          8 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000008       \n[QR_CODE: http://54.247.95.108/fr/verification/01a11b3a-80d1-7cc8-8f67-bde4788c6563]\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-08 11:16:21.939428+00	2026-10-08 11:16:21.493929+00	2026-10-08 11:16:21.946228+00	\N	\N	0
d1cffe21-0966-4057-9a98-fb6e17ea3226	db5be098-d0bf-42f8-91e8-9a1ecd858825	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-08-0007\nTABLE Comptoir      Couverts : 1\nDate            08/10/2026 14:43\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Frites + Boeuf        2 500 F\n1x Attiéké + Poulet      2 500 F\n2x Tamarin               1 000 F\n2x Bissap                1 000 F\n2x Passion               2 000 F\n--------------------------------\nTOTAL TTC            9 000 F CFA\n--------------------------------\nReglement Especes :      9 000 F\nRecu caissier :         10 000 F\nMonnaie rendue :         1 000 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-08 14:43:57.814133+00	2026-10-08 14:43:57.644103+00	2026-10-08 14:43:57.819148+00	\N	\N	0
54a306d4-2804-4003-b968-15e5844dfb80	1ae79c99-2c11-40f4-9b4e-6948b5256aed	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-08-0005\nTABLE Comptoir      Couverts : 1\nDate            08/10/2026 14:46\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Frites + Boeuf        2 500 F\n1x Attiéké + Poulet      2 500 F\n1x Igname frite + Poisso 5 000 F\n1x Alloco + Poulet       2 500 F\n1x Dégué                 1 000 F\n1x Salade de fruits        500 F\n1x Lait                  1 000 F\n1x Tamarin                 500 F\n1x Passion               1 000 F\n2x Bissap                1 000 F\n--------------------------------\nTOTAL TTC           17 500 F CFA\n--------------------------------\nReglement Especes :     17 500 F\nRecu caissier :         20 000 F\nMonnaie rendue :         2 500 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000009       \n[QR_CODE: http://54.247.95.108/fr/verification/01a11bfa-a2ce-7cc8-8f7e-4a46deabfc12]\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-08 14:46:13.282602+00	2026-10-08 14:46:13.162577+00	2026-10-08 14:46:13.285863+00	\N	\N	0
3723b6b7-e724-4272-a623-b8c41734b783	9a9fc6d5-9fb0-4031-929e-50035995d1db	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-08-0008\nTABLE Comptoir      Couverts : 1\nDate            08/10/2026 15:06\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Kope + Poulet  2 500 F\n1x Tamarin                 500 F\n1x Bissap                  500 F\n--------------------------------\nTOTAL TTC            3 500 F CFA\n--------------------------------\nPaiement MOBILE_MONEY :  3 500 F\nRecu caissier :          3 500 F\nMonnaie rendue :             0 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	f	t	f	\N	2026-10-08 15:06:00.515902+00	2026-10-08 15:06:00.382932+00	2026-10-08 15:06:00.519003+00	\N	\N	0
29430dcb-10d6-4463-b6e4-df8288ed5055	867b6c58-13d3-4af8-8f2e-094ae7f69f2c	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-08-0009\nTable 10            Couverts : 4\nDate            08/10/2026 15:06\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Sauce Légume + Poulet 2 500 F\n--------------------------------\nTOTAL TTC            2 500 F CFA\n--------------------------------\nPaiement MOBILE_MONEY :  2 500 F\nRecu caissier :          2 500 F\nMonnaie rendue :             0 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	f	t	f	\N	2026-10-08 15:06:41.041959+00	2026-10-08 15:06:41.005692+00	2026-10-08 15:06:41.045054+00	\N	\N	0
4383751e-f30b-40d5-bdd4-5e9cfa53ed42	ea858ea2-6771-49c3-b09b-253f7cadb4e4	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-13-0005\nTABLE Comptoir      Couverts : 1\nDate            13/10/2026 14:54\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Bissap                  500 F\n2x Passion               2 000 F\n1x Tchep + Poisson       3 000 F\n1x Yassa + Mouton        3 500 F\n--------------------------------\nTOTAL TTC            9 000 F CFA\n--------------------------------\nPaiement MTN MoMo :      9 000 F\nRecu caissier :          9 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	f	t	f	\N	2026-10-13 14:54:35.972872+00	2026-10-13 14:54:35.473759+00	2026-10-13 14:54:35.976166+00	\N	\N	0
272eaf3f-5cc5-40cf-8e75-7cd17b568b97	41ec42f2-0c63-4e29-9fa8-c6b043ea9669	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0001\nTable 1             Couverts : 4\nDate            19/10/2026 14:22\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n2x Tamarin               1 000 F\n2x Attiéké + Sosso       8 000 F\n1x Attiéké + Poulet      2 500 F\n1x Frites + Mouton       3 500 F\n--------------------------------\nTOTAL TTC           15 000 F CFA\n--------------------------------\nReglement Especes :     15 000 F\nRecu caissier :         20 000 F\nMonnaie rendue :         5 000 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:22:39.6383+00	2026-10-19 14:22:39.599434+00	2026-10-19 14:22:39.641968+00	\N	\N	0
57e8ea24-0036-4fab-8bf4-2dbaee87ee13	076109cb-177f-408e-b8d2-1a2ca7c82b9b	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-08-0006\nTable 9             Couverts : 4\nDate            08/10/2026 15:07\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Couscous + Poulet     2 500 F\n1x Tchep + Mouton        3 500 F\n1x Attiéké + Poulet      2 500 F\n1x Sauce Légume + Poulet 2 500 F\n1x Salade de fruits        500 F\n1x Dégué                 1 000 F\n2x Lait                  2 000 F\n2x Tamarin               1 000 F\n1x Bissap                  500 F\n1x Passion               1 000 F\n--------------------------------\nTOTAL TTC           17 000 F CFA\n--------------------------------\nPaiement MOBILE_MONEY : 17 000 F\nRecu caissier :         17 000 F\nMonnaie rendue :             0 F\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	f	t	f	\N	2026-10-08 15:07:18.374799+00	2026-10-08 15:07:18.333662+00	2026-10-08 15:07:18.377996+00	\N	\N	0
9bb7afd2-feff-4b55-8493-dd6e2f4ca694	e6ff5588-1a97-409f-b651-8dcd1ec5135b	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-08-0004\nTable 4             Couverts : 4\nDate            08/10/2026 15:13\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Dah + Poulet   2 500 F\n1x Kabato Dah + Mouton   3 500 F\n1x Kabato Kope + Mouton  3 500 F\n1x Tamarin                 500 F\n3x Bissap                1 500 F\n--------------------------------\nTOTAL TTC           11 500 F CFA\n--------------------------------\nReglement Especes :     11 500 F\nRecu caissier :         12 000 F\nMonnaie rendue :           500 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000010       \n[QR_CODE: http://54.247.95.108/fr/verification/01a11c13-d7ef-7cc8-8f7e-a99af004de76]\n--------------------------------\nMerci de votre visite et à très \n           bientôt !            	t	t	f	\N	2026-10-08 15:13:45.235201+00	2026-10-08 15:13:45.112009+00	2026-10-08 15:13:45.238076+00	\N	\N	0
776bea63-e13a-44b7-9776-614e16d8c8d0	c7b4ce76-37d6-4963-83b6-5da7c270aa02	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-13-0002\nTABLE Comptoir      Couverts : 1\nDate            13/10/2026 12:20\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Sauce Feuille + Mouto 3 500 F\n1x Tamarin                 500 F\n1x Sauce Légume + Poisso 3 000 F\n1x Bissap                  500 F\n1x Sauce Dah + Poulet    2 500 F\n--------------------------------\nTOTAL TTC           10 000 F CFA\n--------------------------------\nPaiement Wave :         10 000 F\nRecu caissier :         10 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000011       \n[QR_CODE: http://54.247.95.108/fr/verification/01a13535-33d8-7eed-8c9a-2998e3217b42]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	f	t	f	\N	2026-10-13 12:20:42.115883+00	2026-10-13 12:20:41.68076+00	2026-10-13 12:20:42.119911+00	\N	\N	0
99d1ca98-dbbf-4eb0-80ea-68ca40bf004c	39bd2f25-6504-419b-b010-af921b9e733a	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-13-0001\nTABLE Comptoir      Couverts : 1\nDate            13/10/2026 12:22\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Salade Panachée + Sos 4 000 F\n1x Tamarin                 500 F\n1x Salade Panachée + Pou 2 500 F\n1x Bissap                  500 F\n--------------------------------\nTOTAL TTC            7 500 F CFA\n--------------------------------\nPaiement Orange Money :  7 500 F\nRecu caissier :          7 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	f	t	f	\N	2026-10-13 12:22:25.239877+00	2026-10-13 12:22:25.203302+00	2026-10-13 12:22:25.243271+00	\N	\N	0
51c9b789-6607-4c41-a8d8-369f5f10fc3c	70e4726f-ac39-499c-9e84-97f3ccd8b1d1	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-13-0003\nTable 10            Couverts : 4\nDate            13/10/2026 12:23\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Bissap                  500 F\n1x Passion               1 000 F\n1x Frites + Boeuf        2 500 F\n1x Alloco + Poisson brai 5 000 F\n1x Attiéké + Boeuf       2 500 F\n1x Alloco + Poulet       2 500 F\n--------------------------------\nTOTAL TTC           14 000 F CFA\n--------------------------------\nReglement Especes :     14 000 F\nRecu caissier :         15 000 F\nMonnaie rendue :         1 000 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-13 12:23:48.105948+00	2026-10-13 12:23:48.069479+00	2026-10-13 12:23:48.109211+00	\N	\N	0
ff2106c5-3ea5-4a62-9f4c-c0bf1d36fd6b	e39da534-1326-47b7-a6e2-b3bdccfbd904	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-13-0004\nTable 9             Couverts : 4\nDate            13/10/2026 14:56\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Lafri + Poulet 2 500 F\n1x Bissap                  500 F\n1x Tamarin                 500 F\n1x Couscous + Poulet     2 500 F\n--------------------------------\nTOTAL TTC            6 000 F CFA\n--------------------------------\nReglement Especes :      6 000 F\nRecu caissier :         10 000 F\nMonnaie rendue :         4 000 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000012       \n[QR_CODE: http://54.247.95.108/fr/verification/01a135c3-6ba4-7223-99ef-8622b369e98f]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-13 14:56:02.192305+00	2026-10-13 14:56:02.156755+00	2026-10-13 14:56:02.195294+00	\N	\N	0
76431eb1-7cfd-43c3-95d8-76239ca73d90	998f84b2-586b-47c9-98ce-bcd1becca088	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-14-0002\nTable 3             Couverts : 4\nDate            14/10/2026 15:23\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Igname bouillie + Poi 5 000 F\n1x Tchep + Poisson       3 000 F\n1x Salade Panachée + Poi 5 000 F\n--------------------------------\nTOTAL TTC           13 000 F CFA\n--------------------------------\nReglement Especes :     13 000 F\nRecu caissier :         13 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      FNE-2026-10-14-0002       \n[QR_CODE: http://54.247.95.108/fr/verification/2026-10-14-0002]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-14 15:23:51.281943+00	2026-10-14 15:23:51.191907+00	2026-10-14 15:23:51.286896+00	\N	\N	0
ec5eec2f-b77f-4468-9bb4-633dc26228f8	ce2dd852-2947-4e23-b62e-4d8df1a69490	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-14-0004\nTable 3             Couverts : 4\nDate            14/10/2026 15:35\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Kope + Tripe   2 500 F\n1x Tamarin                 500 F\n1x Bissap                  500 F\n--------------------------------\nTOTAL TTC            3 500 F CFA\n--------------------------------\nReglement Especes :      3 500 F\nRecu caissier :          5 000 F\nMonnaie rendue :         1 500 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-14 15:35:30.361316+00	2026-10-14 15:35:30.32474+00	2026-10-14 15:35:30.364381+00	\N	\N	0
5bbe85e2-24ce-4d3b-b829-7b543a9a1068	4a6a29a6-e2a8-4c80-928e-7edf6a6c5fd8	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-14-0003\nTABLE Comptoir      Couverts : 1\nDate            14/10/2026 16:55\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Kope + Tripe   2 500 F\n--------------------------------\nTOTAL TTC            2 500 F CFA\n--------------------------------\nReglement Especes :      2 500 F\nRecu caissier :          3 000 F\nMonnaie rendue :           500 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-14 16:55:33.587594+00	2026-10-14 16:55:33.519112+00	2026-10-14 16:55:33.591607+00	\N	\N	0
02a3a58d-7d09-4f37-8840-495f3bab472d	1d99a39f-4263-4b0f-b6dd-6544080aab4a	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-14-0001\nTable 2             Couverts : 4\nDate            14/10/2026 16:56\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Tchep + Mouton        3 500 F\n1x Salade Panachée + Sos 4 000 F\n1x Salade de fruits        500 F\n1x Bissap                  500 F\n1x Passion               1 000 F\n--------------------------------\nTOTAL TTC            9 500 F CFA\n--------------------------------\nReglement Especes :      9 500 F\nRecu caissier :         10 000 F\nMonnaie rendue :           500 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000014       \n[QR_CODE: http://54.247.95.108/fr/verification/01a13b57-a79f-7223-9a06-c77057ca4d80]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-14 16:56:02.874623+00	2026-10-14 16:56:02.852521+00	2026-10-14 16:56:02.878162+00	\N	\N	0
b137a206-074a-4ffc-9ded-d7bed835154a	f2fb511b-1bdd-4b34-8174-1b6c7ab582b0	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0001\nTable 3             Couverts : 4\nDate            15/10/2026 11:51\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Lafri + Tripe  2 500 F\n1x Salade Panachée + Poi 5 000 F\n1x Salade Panachée + Sos 4 000 F\n1x Tamarin                 500 F\n1x Bissap                  500 F\n1x Frites + Boeuf        2 500 F\n1x Attiéké + Poulet      2 500 F\n1x Passion               1 000 F\n--------------------------------\nTOTAL TTC           18 500 F CFA\n--------------------------------\nReglement Especes :     18 500 F\nRecu caissier :         20 000 F\nMonnaie rendue :         1 500 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-15 11:51:48.077116+00	2026-10-15 11:51:47.880132+00	2026-10-15 11:51:48.081013+00	\N	\N	0
17496bc3-187a-48aa-a4af-bfbef01a4441	ee578b03-ff99-40a0-9313-02085d248038	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0002\nTable 3             Couverts : 1\nDate            15/10/2026 11:52\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Dah + Tripe    2 500 F\n2x Kabato Lafri + Boeuf  5 000 F\n1x Tchep + Poisson       3 000 F\n1x Dégué                 1 000 F\n--------------------------------\nTOTAL TTC           11 500 F CFA\n--------------------------------\nPaiement Wave :         11 500 F\nRecu caissier :         11 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	f	t	f	\N	2026-10-15 11:52:47.173066+00	2026-10-15 11:52:47.136786+00	2026-10-15 11:52:47.177434+00	\N	\N	0
1be447cb-0320-49e4-9d82-907ffef9c980	04f24f74-7622-466b-b090-0f065946e004	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0005\nTABLE Comptoir      Couverts : 1\nDate            15/10/2026 12:14\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Frites + Boeuf        2 500 F\n1x Attiéké + Sosso       4 000 F\n1x Attiéké + Poisson bra 5 000 F\n2x Salade de fruits      1 000 F\n2x Tamarin               1 000 F\n--------------------------------\nTOTAL TTC           13 500 F CFA\n--------------------------------\nReglement Especes :     13 500 F\nRecu caissier :         15 000 F\nMonnaie rendue :         1 500 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-15 12:14:45.773061+00	2026-10-15 12:14:45.363354+00	2026-10-15 12:14:45.777286+00	\N	\N	0
b1f8b2bd-682d-41bf-b903-532a8169379e	68380b5e-667a-4c22-b3b3-a4b9e0674607	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0004\nTable 2             Couverts : 4\nDate            15/10/2026 15:12\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Salade de fruits        500 F\n1x Couscous + Poulet     2 500 F\n--------------------------------\nTOTAL TTC            3 000 F CFA\n--------------------------------\nReglement Especes :      3 000 F\nRecu caissier :          3 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-15 15:12:03.84104+00	2026-10-15 15:12:03.437342+00	2026-10-15 15:12:03.850402+00	\N	\N	0
24623428-f770-498e-9483-6a8ae4c881d4	778a91c8-9cce-44e7-91b9-e5ff90fd0a23	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0006\nTable 8             Couverts : 4\nDate            15/10/2026 16:41\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Lafri + Tripe  2 500 F\n1x Attiéké + Sosso       4 000 F\n1x Attiéké + Boeuf       2 500 F\n1x Alloco + Sosso        4 000 F\n2x Bissap                1 000 F\n2x Passion               2 000 F\n--------------------------------\nTOTAL TTC           16 000 F CFA\n--------------------------------\nReglement Especes :     16 000 F\nRecu caissier :         16 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-15 16:41:09.163329+00	2026-10-15 16:41:08.980813+00	2026-10-15 16:41:09.173872+00	\N	\N	0
75b5415a-c717-4f37-969c-806eb25413ef	3f8f8dc6-11b6-4706-9a16-5033b227f0d1	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0002\nTABLE Comptoir      Couverts : 1\nDate            19/10/2026 14:20\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Tchep + Mouton        3 500 F\n1x Tchep + Poisson       3 000 F\n1x Tamarin                 500 F\n1x Bissap                  500 F\n--------------------------------\nTOTAL TTC            7 500 F CFA\n--------------------------------\nReglement Especes :      7 500 F\nRecu caissier :          8 000 F\nMonnaie rendue :           500 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:20:52.811928+00	2026-10-19 14:20:52.469567+00	2026-10-19 14:20:52.815955+00	\N	\N	0
6e57b71f-f69e-4646-baf8-b3a1ab2c49e7	9a9daf47-c991-4852-b474-f2d9c12f44ec	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0008\nTable 3             Couverts : 1\nDate            16/10/2026 09:55\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Couscous + Poulet     2 500 F\n1x Couscous + Poisson    3 000 F\n--------------------------------\nTOTAL TTC            5 500 F CFA\n--------------------------------\nReglement Especes :      5 500 F\nRecu caissier :          5 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000015       \n[QR_CODE: http://54.247.95.108/fr/verification/01a14423-9a31-7223-9a43-ded6f760e4b2]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-16 09:55:46.740382+00	2026-10-16 09:55:46.503053+00	2026-10-16 09:55:46.747084+00	\N	\N	0
067166f3-b112-44ed-8bd9-4f840b7cb66d	722b3daf-c534-4a28-96a1-c7f866dcb6e4	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0007\nTable 3             Couverts : 4\nDate            16/10/2026 10:02\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Tchep + Mouton        3 500 F\n1x Tchep + Poisson       3 000 F\n1x Tamarin                 500 F\n1x Bissap                  500 F\n--------------------------------\nTOTAL TTC            7 500 F CFA\n--------------------------------\nReglement Especes :      7 500 F\nRecu caissier :          7 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000016       \n[QR_CODE: http://54.247.95.108/fr/verification/01a14429-50ee-7eed-8cee-984840f2f730]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-16 10:02:01.046998+00	2026-10-16 10:02:01.008615+00	2026-10-16 10:02:01.051346+00	\N	\N	0
bdb3d023-f7eb-49f1-b0f3-f3b044a26b17	e8a42cf0-5a2f-41e7-85db-4a8ba423084d	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0010\nTABLE Comptoir      Couverts : 1\nDate            16/10/2026 10:25\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Kope + Poulet  2 500 F\n1x Kabato Lafri + Poisso 3 000 F\n--------------------------------\nTOTAL TTC            5 500 F CFA\n--------------------------------\nReglement Especes :      5 500 F\nRecu caissier :          5 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-16 10:25:56.852997+00	2026-10-16 10:25:56.621847+00	2026-10-16 10:25:56.869885+00	\N	\N	0
0062b664-5f00-497f-9520-8984743be713	3caa47f0-5560-456a-830e-e0e31694dc3d	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-15-0009\nTable 9             Couverts : 4\nDate            16/10/2026 10:26\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Lafri + Poisso 3 000 F\n1x Frites + Boeuf        2 500 F\n1x Alloco + Mouton       3 500 F\n1x Igname frite + Mouton 3 500 F\n--------------------------------\nTOTAL TTC           12 500 F CFA\n--------------------------------\nReglement Especes :     12 500 F\nRecu caissier :         12 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-16 10:26:17.666975+00	2026-10-16 10:26:17.63+00	2026-10-16 10:26:17.670159+00	\N	\N	0
71bdb4a2-929d-4649-aa16-62f5f05f0606	a898bc47-55b9-4ec3-a2e7-19e82a3d0552	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0007\nTable 4             Couverts : 4\nDate            19/10/2026 14:39\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Igname bouillie + Mou 3 500 F\n1x Attiéké + Sosso       4 000 F\n1x Igname bouillie + Sos 4 000 F\n4x Tamarin               2 000 F\n--------------------------------\nTOTAL TTC           13 500 F CFA\n--------------------------------\nReglement Especes :     13 500 F\nRecu caissier :         15 000 F\nMonnaie rendue :         1 500 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000017       \n[QR_CODE: http://54.247.95.108/fr/verification/01a1549a-2944-7223-9a60-57d96390c3b0]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:39:12.214453+00	2026-10-19 14:39:11.893406+00	2026-10-19 14:39:12.21787+00	\N	\N	0
b222e535-e7b1-4867-a13d-c365ff043ebb	e7997130-0ca2-4611-9a0f-547906350cfc	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0009\nTable 7             Couverts : 4\nDate            19/10/2026 14:41\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Lafri + Tripe  2 500 F\n1x Salade Panachée + Sos 4 000 F\n1x Salade Panachée + Poi 5 000 F\n1x Igname bouillie + Poi 5 000 F\n1x Igname frite + Mouton 3 500 F\n1x Salade de fruits        500 F\n--------------------------------\nTOTAL TTC           20 500 F CFA\n--------------------------------\nReglement Especes :     20 500 F\nRecu caissier :         21 000 F\nMonnaie rendue :           500 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000018       \n[QR_CODE: http://54.247.95.108/fr/verification/01a1549c-464f-7eed-8d0c-0c720b610b4d]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:41:30.392264+00	2026-10-19 14:41:30.323841+00	2026-10-19 14:41:30.394631+00	\N	\N	0
19c99947-3d92-451a-bfa0-fa94573ebd7d	8c1faad9-c719-4e21-bd8b-e3db15751754	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0013\nTABLE Comptoir      Couverts : 1\nDate            19/10/2026 14:42\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Tchep + Poisson       3 000 F\n1x Yassa + Boeuf         2 500 F\n1x Tchep + Mouton        3 500 F\n2x Bissap                1 000 F\n--------------------------------\nTOTAL TTC           10 000 F CFA\n--------------------------------\nReglement Especes :     10 000 F\nRecu caissier :         10 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:42:39.228996+00	2026-10-19 14:42:39.209968+00	2026-10-19 14:42:39.231254+00	\N	\N	0
160416a7-6958-4791-91e8-3ddd1aa8ecc8	dec8e488-1dc9-48fc-a597-47ca3a193e10	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0010\nTable 9             Couverts : 4\nDate            19/10/2026 14:44\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Dégué                 1 000 F\n1x Tamarin                 500 F\n1x Bissap                  500 F\n--------------------------------\nTOTAL TTC            2 000 F CFA\n--------------------------------\nReglement Especes :      2 000 F\nRecu caissier :          2 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:44:09.595242+00	2026-10-19 14:44:09.576986+00	2026-10-19 14:44:09.597842+00	\N	\N	0
8e0eb1dc-8339-438f-92b2-a1da623a23d4	82620f6e-2b11-4bc8-b541-aac6644dc809	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0004\nTable 1             Couverts : 4\nDate            19/10/2026 14:44\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Dah + Tripe    2 500 F\n1x Kabato Dah + Poisson  3 000 F\n1x Tchep + Mouton        3 500 F\n1x Tamarin                 500 F\n1x Bissap                  500 F\n--------------------------------\nTOTAL TTC           10 000 F CFA\n--------------------------------\nReglement Especes :     10 000 F\nRecu caissier :         10 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:44:26.418684+00	2026-10-19 14:44:26.400243+00	2026-10-19 14:44:26.421228+00	\N	\N	0
3f8df834-38b9-4dd7-b632-07e047bef0db	234ba969-bf26-4b05-88fa-6f0de2f6664d	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0003\nTable 5             Couverts : 4\nDate            19/10/2026 14:45\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Dah + Poulet   2 500 F\n1x Tchep + Poisson       3 000 F\n1x Couscous + Poulet     2 500 F\n1x Sauce Feuille + Poule 2 500 F\n1x Salade de fruits        500 F\n--------------------------------\nTOTAL TTC           11 000 F CFA\n--------------------------------\nPaiement Wave :         11 000 F\nRecu caissier :         11 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	f	t	f	\N	2026-10-19 14:45:04.450153+00	2026-10-19 14:45:04.431911+00	2026-10-19 14:45:04.45382+00	\N	\N	0
bfec0c40-1c73-45a8-a91a-89a64e9decee	4630958e-a91c-426c-8d21-13cc50daf48c	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0014\nTable 8             Couverts : 1\nDate            19/10/2026 14:53\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n2x Bissap                1 000 F\n1x Salade Panachée + Sos 4 000 F\n--------------------------------\nTOTAL TTC            5 000 F CFA\n--------------------------------\nReglement Especes :      5 000 F\nRecu caissier :          5 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:53:52.313432+00	2026-10-19 14:53:52.294969+00	2026-10-19 14:53:52.316378+00	\N	\N	0
c66f149b-b2fc-4874-91d9-b573948a640b	b1ef6b2c-1593-4c4e-a800-8541ebf5aeb1	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0012\nTable 10            Couverts : 4\nDate            19/10/2026 14:45\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Couscous + Poulet     2 500 F\n1x Salade Panachée + Poi 5 000 F\n1x Kabato Dah + Poulet   2 500 F\n1x Salade Panachée + Sos 4 000 F\n1x Kabato Kope + Poisson 3 000 F\n1x Couscous + Poisson    3 000 F\n--------------------------------\nTOTAL TTC           20 000 F CFA\n--------------------------------\nPaiement MTN MoMo :     20 000 F\nRecu caissier :         20 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	f	t	f	\N	2026-10-19 14:45:32.375967+00	2026-10-19 14:45:32.357314+00	2026-10-19 14:45:32.37808+00	\N	\N	0
c653bebf-1379-418c-9c8b-d392e0067238	6138d6a8-6f96-47ed-b093-baf0cfb04fa8	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0011\nTable 6             Couverts : 4\nDate            19/10/2026 14:46\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Petit pois + Sosso    4 500 F\n1x Alloco + Poulet       2 500 F\n2x Tchep + Poulet        5 000 F\n--------------------------------\nTOTAL TTC           12 000 F CFA\n--------------------------------\nPaiement Orange Money : 12 000 F\nRecu caissier :         12 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	f	t	f	\N	2026-10-19 14:46:12.419504+00	2026-10-19 14:46:12.352943+00	2026-10-19 14:46:12.421282+00	\N	\N	0
e3fda46a-07ca-4f15-b43a-aee180f50eed	9187a7af-42c4-4b1e-98df-51cf420ae7c0	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0005\nTable 3             Couverts : 4\nDate            19/10/2026 14:47\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Kope + Poulet  2 500 F\n1x Kabato Dah + Poisson  3 000 F\n1x Kabato Kope + Poisson 3 000 F\n1x Salade de fruits        500 F\n--------------------------------\nTOTAL TTC            9 000 F CFA\n--------------------------------\nPaiement Moov Money :    9 000 F\nRecu caissier :          9 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	f	t	f	\N	2026-10-19 14:47:33.544933+00	2026-10-19 14:47:33.427882+00	2026-10-19 14:47:33.547392+00	\N	\N	0
12ae39bf-b451-4669-8543-ff8f1e42af25	f1c7d23d-fe31-429b-8723-b5582ccba29c	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0006\nTable 2             Couverts : 4\nDate            19/10/2026 14:51\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Sauce Légume + Boeuf  2 500 F\n1x Sauce Dah + Mouton    3 500 F\n1x Sauce Feuille + Poiss 3 000 F\n1x Sauce Légume + Poisso 3 000 F\n--------------------------------\nTOTAL TTC           12 000 F CFA\n--------------------------------\nReglement Especes :     12 000 F\nRecu caissier :         15 000 F\nMonnaie rendue :         3 000 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:51:28.682255+00	2026-10-19 14:51:28.663866+00	2026-10-19 14:51:28.685179+00	\N	\N	0
8094f858-f856-4b99-9437-a08e0a5760f1	0de42b32-d7ff-4fb3-b6f7-bf09b3c5a22c	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-19-0008\nTable 8             Couverts : 4\nDate            19/10/2026 14:53\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Couscous + Poulet     2 500 F\n1x Couscous + Mouton     3 500 F\n3x Bissap                1 500 F\n--------------------------------\nTOTAL TTC            7 500 F CFA\n--------------------------------\nReglement Especes :      7 500 F\nRecu caissier :         10 000 F\nMonnaie rendue :         2 500 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000019       \n[QR_CODE: http://54.247.95.108/fr/verification/01a154a6-e55a-7223-9a60-70aab67bb784]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-19 14:53:06.64816+00	2026-10-19 14:53:06.430253+00	2026-10-19 14:53:06.651763+00	\N	\N	0
f4c8981f-95c4-43cf-8a04-c3554cc023bb	cfdf234b-e450-4b8d-a49a-863dc774908e	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-20-0001\nTable 3             Couverts : 4\nDate            20/10/2026 11:33\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Kabato Dah + Poulet   2 500 F\n1x Tchep + Mouton        3 500 F\n--------------------------------\nTOTAL TTC            6 000 F CFA\n--------------------------------\nReglement Especes :      6 000 F\nRecu caissier :          6 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     FACTURE NORMALISEE DGI     \n      1304777N26000000020       \n[QR_CODE: http://54.247.95.108/fr/verification/01a15916-f474-7223-9a9f-15e2057c2667]\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-20 11:33:59.471289+00	2026-10-20 11:33:59.179244+00	2026-10-20 11:33:59.481889+00	\N	\N	0
e7ca8159-8857-4423-9676-aba154fc5f03	355aa3fe-84db-4a21-8310-a24e00d52726	RECEIPT	DONE	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-20-0002\nTable 3             Couverts : 1\nDate            20/10/2026 16:41\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Tchep + Poulet        2 500 F\n2x Tamarin               1 000 F\n--------------------------------\nTOTAL TTC            3 500 F CFA\n--------------------------------\nReglement Especes :      3 500 F\nRecu caissier :          3 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	2026-10-20 16:41:50.331845+00	2026-10-20 16:41:50.294091+00	2026-10-20 16:41:50.334913+00	\N	\N	0
751db13a-b8e6-4693-bfb9-2adb0e9dc981	9d70470c-a448-4666-8a3b-26a894e407ad	RECEIPT	QUEUED	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-22-0002\nTable 1             Couverts : 1\nDate            22/10/2026 19:10\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Foufou/foutou faux br 3 500 F\n--------------------------------\nTOTAL TTC            3 500 F CFA\n--------------------------------\nReglement Especes :      3 500 F\nRecu caissier :          3 500 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	\N	2026-10-22 19:10:58.644891+00	2026-10-22 19:10:58.64492+00	\N	\N	0
47df885c-a9f9-424c-8473-76cf196586bb	c259aa5a-5c56-48e4-af2d-2cd301af43d8	RECEIPT	QUEUED	[LOGO]\n        Abidjan, Plateau        \n     Tel : +225 0102030405      \n         NCC : 1234567A         \n--------------------------------\nTicket           2026-10-22-0001\nTable 1             Couverts : 4\nDate            22/10/2026 19:11\nCaissier              Digui Thio\n--------------------------------\nARTICLES                    PRIX\n--------------------------------\n1x Salade Panachée + Pou 2 500 F\n1x Salade Panachée + Sos 4 000 F\n1x Jus de citron           500 F\n--------------------------------\nTOTAL TTC            7 000 F CFA\n--------------------------------\nReglement Especes :      7 000 F\nRecu caissier :          7 000 F\nMonnaie rendue :             0 F\n--------------------------------\n     Merci de votre visite      \n        à très bientôt !        	t	t	f	\N	\N	2026-10-22 19:11:12.301767+00	2026-10-22 19:11:12.301816+00	\N	\N	0
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
873388b4-9572-48d0-a73a-75c6f085085a	d06c79a2-0485-4ee2-bfc4-10d740c69241	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
9fcc9a46-aef8-420a-bb7e-2a74bb8af3e9	c56c3a9c-5317-4e3e-be7b-1bed326fe53f	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
394d024b-4735-454c-98bf-7b6a363643e7	120dc3c0-0932-4219-94d7-01f56c5e1139	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
315b5f43-f1c2-42aa-a968-e65ffc6d528f	ceafb668-7cd6-4c8f-90cd-f44a62dc5c26	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
35e66299-8514-4dac-8ab2-7b3d2b822a9a	11d8e671-0244-4066-854d-eede1fb90a58	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
92ba9380-394f-4028-b831-0fae198b67aa	bfee22fc-f027-48c3-92af-f2f2f6e6145b	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
9274d691-63e0-4a78-a73c-7e9a3e684e47	f0dd6e5d-fc7f-4518-b2a4-731ef5de1bec	07ee94bb-1c62-4d20-b9e3-9b2aa9132f4a	0.250
c1091030-df31-4326-b852-bcd59a1dfa0b	601cc27a-9aad-4b65-935b-ec59b39a2e5b	258570a6-aee0-4adb-a7e1-526f56b06506	1.000
e03e309b-a34c-465b-aec0-347363f2dcc8	01dbc122-a427-4ddb-ac94-6281b3301c7e	258570a6-aee0-4adb-a7e1-526f56b06506	1.000
b92e8082-310c-4d85-85e6-3f45a70290e4	f2ed4eac-2031-4814-af66-619be36324f0	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
9e656f5a-f9f0-429d-9319-23c212d4150e	e0648d5b-df64-444f-82cf-0d18b472b3db	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
b5711bb3-c262-4c8c-83fc-42b16879ee18	9e31b16b-aac4-4431-9012-60dcc2e4e0d9	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
651d2a6d-5a17-498b-ada5-0eaa1f0b693e	23c6c6ec-ad5a-4626-8bfb-0076cf03534d	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
be0bf492-8556-4f54-94c0-7967eba1854d	4f84df00-4f47-4ba8-b119-ea5e01d7d16c	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
07e1e3fd-ab3b-46a0-8bba-67875a6d9a67	c6ba2d3b-c3bd-42ba-b0d2-9adf3e1ad10f	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
f3d21b62-7744-4d8b-a61c-45e1e040b7e5	53dbcb50-bebb-4593-9e98-27e713d3da4d	5e5c8e90-160b-4766-abc5-0b06087c6456	1.000
722f268c-fbf1-4546-97c8-014f869cbe62	5839313f-ebfa-478e-b99c-b79a1b75b313	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
f3e28a02-c1ba-4830-b1fb-a845d7b95f9a	6b776576-c91e-4151-b22b-d05e320b2f30	0e520485-53a3-403a-8dc8-547417bb83e4	1.000
cebfd77d-18aa-44f4-93a9-8f2cf4d8dbd6	da028acf-3dee-46cb-a28d-60a205795865	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	0.500
cc58845c-a344-42cc-95a2-1054f56adf19	882bccb2-37b1-4ce0-ae49-976744d001de	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	0.500
8eb65726-6f9f-46a6-ac75-e7dda73d96d9	9d0f0b4f-a32e-42f5-b23d-692d756cb566	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	0.500
bc2ea68d-fdac-4257-b262-d3d780f538a0	be1c321d-e8ad-4910-b02e-412d149b7595	2cad3fbe-c8cf-4dc8-9a9c-3c39831d69e1	1.000
6ccba3e1-d129-4726-a602-f77c4a55f731	5cbd0c22-be56-429e-b0ea-07e3dd917763	d9fbe76f-9256-4c7e-9f98-5f9a1f4b0c3d	1.000
b6469a15-da6a-46b6-9b8b-88f3dda303e8	00fc07e5-eee4-4d2b-afe7-a965d7a8ebb8	c3165735-9157-4879-b272-a6807c36d677	1.000
b7f74018-6121-4c44-b0bf-eb63da313332	60621b43-1544-48ec-ac29-4b90c955c8da	54d0c628-235d-4f09-b026-ab073c650261	1.000
2e1fe311-5f9f-4480-85a8-4523e53407e8	c718be08-114b-480b-8367-75cb510147cd	25fd53a8-c277-418d-a596-b575ce7f784a	1.000
8d956b9c-c02f-4b5b-aceb-e3d0e301ea12	b809a15b-9263-4a5e-8412-a09959a2c846	0edc867d-1dfa-4bdc-8988-8401299297b9	1.000
ee05541e-a09f-4f82-9fdf-007aaf67b4a2	a90e5445-f9cc-489a-8add-b74b9730ac84	fb615c0d-0da1-44bb-9a49-c1e3a3d772b2	1.000
88fa2efd-d156-4b19-8684-90669d47cd18	b09de5c7-8ea7-428e-ac90-6ae2d292dfff	b9e7f197-7df5-4ffd-ab80-e033bfe823bd	1.000
b140639a-d0e0-461d-b5f0-06fac9e6db0e	80be8cd4-9d9a-423b-970d-0f7d138c779b	9c44e792-4724-46eb-a278-875e6ce514a8	1.000
74fd6bf2-41a5-4353-824f-d430f6b771c9	8ce39ccb-16c7-4aba-8b93-899cd3bff4fa	21c0a4c6-64c9-4223-a0c3-fee4ef7ebd1f	1.000
01cf129c-0916-48db-8ba2-7062135e7380	b7299606-d51a-490f-8360-ead14cd488f6	6a7dc7ed-7a51-4954-9d06-68b9bd08d74c	1.000
cafa9e62-e33c-4423-a59a-fa4f6f53ba89	a8947a20-8f0a-419f-87c3-b4ece1515cd1	6860e5c8-8643-46d2-a6e9-bfe6e9fc80a0	1.000
f1cac2fc-2fd0-4ff7-8606-55f08ba92873	fac8d34f-d617-4742-b911-9b16b952df69	8ca7f94b-d3d9-4a5e-860b-6a500b0d3502	1.000
b2efedc2-58a0-4f73-99ab-24692cad6950	204cd496-4aba-44d0-b3a1-919bb4386000	edba16c2-09c9-47b2-977e-82d92a6b0582	1.000
f66466f8-1844-45af-b084-e96ed5be7941	69a7d8cd-f428-4211-803a-11fea038e56e	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
eb6e9f79-1d3a-4322-8fcd-6bea39e134af	5890cd36-f149-4667-9aa7-03375d3a31af	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
fae2d14d-92d5-4dbc-a035-bccfefadf88a	1dcc3350-2fdb-4653-a60f-ec1212bb682e	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
83dc2b7d-4c58-4e46-983d-c7513e56da55	7e2e9acc-4cb0-4222-8e04-e09402820956	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
8ef21341-1894-4c6f-bf7c-9f0b9f26533d	fac18978-1efd-4b64-99a7-75758a3d73c6	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
39cd00f0-2354-4fce-85eb-4b71b178be83	659bc0ec-f84d-4116-a67b-d586d5673641	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
c0779df0-e40e-4831-bb34-9dfe0e5bcf2d	46a09e73-28f4-4df9-984a-95ac939cfe1a	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
add34dc9-a7bf-4e16-8b02-f8fa191a4321	3b9b5a6b-329f-4622-97ec-10226e8d5116	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
68957867-8ab5-4451-85d5-d65edb623d9a	4c60f063-cc76-4d22-a8ae-00001fdf4675	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
c3aeef60-5a23-4d50-a0b6-258f67b4990c	e2028931-16ad-47cd-a58c-03359d67788d	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
13af7434-5702-4607-b43f-f7b390011755	19a0e1b1-b889-4cf6-b553-017f739929aa	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
0c60ae58-baca-46b1-a5c7-b560549c5b90	e2551239-6d21-4a43-aac3-f435b261884e	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
048c734e-d3fe-4aaf-b0ab-9972f4d4f57a	07ce2e45-1d07-45f3-8512-354a71348561	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
0320f48a-df14-4e73-b61b-5817b089c71e	8a5290af-0957-4c14-a42b-88c6f7069761	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
5994f271-3269-4091-948b-4064c665f5ed	4f182459-6a5a-492e-8037-46ce31108923	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
75fd76b8-eec8-4509-b433-b3209e34d975	f7e925d5-6ce1-4a66-90d5-d48e28cec819	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
2c99a046-eb3a-48b5-a19a-b9e1c4a10a22	294aaf86-b061-4edb-9d76-83f43e34ca46	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
5fb4b69a-c07a-4f30-b948-755ad5e63b89	485b3d43-e043-4221-bb72-80d9a5095767	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
cb0ebda2-db87-4244-acdf-58df73d961b8	fae9bc78-c632-44ec-a196-9e9f7f970fa0	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
72e4dfda-a048-4d79-8cbd-b2d293a30e2c	61a1aced-7d78-4d7d-9782-557a2e6622ec	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
d39608a2-782c-43a3-97ef-08405fcbc84c	dbf93f42-7b4c-4c7e-a873-10f18a2151b0	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
29c7ba56-14f0-4e66-8b9d-18059268e5c3	d74871da-b9f7-4a56-9a8a-9519599bf1be	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
d71392aa-9d09-4c57-9fbc-1c5bac9b948e	de76dbf1-aaab-4bac-9278-2e420f6eeaf3	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
5f7a5b8e-201d-4140-9c47-9d1cbd739b3c	3acf88aa-9368-4a0b-a967-3e79d26c59dc	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
c96a822f-723e-41c1-ad29-2b10f80e95c0	0c8c099a-1d4b-4c78-be70-a2f846f9ce63	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
c7b833e2-18dc-4639-8e82-777e757bfd5e	934dde37-9033-45e6-86ed-7cdd2215b18e	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
cd1354ca-a9fc-48b4-a01d-0db2478fc1ea	f2ceb9f5-5bbe-4b7d-8f8d-87fa4e9cc0db	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
50b0dc62-95bf-4ce8-848f-a693c5fb1410	5a718736-9643-4ae4-824e-1c05f6d093dd	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
8d372a5d-4e7a-437c-b240-9836d06b1142	fbb74d1d-e719-4478-b4fb-df4a903e41d5	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
20477653-613f-4e28-b51a-620c178d131e	78a775c5-9a24-4760-a370-483ebc35cd3d	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
58f2da20-96e1-4637-95b0-296270e9e794	e187c501-7b39-497d-95d8-832d0aa0ac66	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
ef5902df-8167-42bb-8f5b-d6aa2edb7e68	17f3e970-a0fa-4fac-8a67-e727f9b6e1e5	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
cc31d2d6-3fe0-42ab-b3fd-07086b955274	f94e741c-9149-45e1-bdef-6e528dd57040	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
e0f42201-2387-46c0-9b98-af7d7c017ae1	9789ad02-8eb7-46f3-8ce5-cf30a399add6	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
3f518688-afa6-4c3e-9eef-2f258d18dafb	ff490dae-af6c-44b1-b8b7-71db1607bd67	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
e60fd949-6da1-4111-b391-137155292cf6	f1e3cc01-c0cd-4013-b667-504db4e7e954	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
0c18ddcc-43bf-4be3-87cc-c31f15fbc36c	07f0b52a-05a5-4410-ad92-6c1b643c6110	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
6676bb32-4124-4585-9e6a-008a543e4a07	74da32a1-1f86-422a-afcf-f431b9765c75	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
a037d30a-27aa-44df-924c-d77e4c8e6f9c	da7a9d7b-64d7-46e9-9a66-fb411d1976e5	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
e7782f27-8278-4077-9093-3c7fcb6af5bc	ac8fa3d4-8c39-4545-bc97-ecf4cd527d49	a4cbfa56-e146-4cec-b536-34c376c34e28	1.000
5f5d68c9-dbb5-4417-8035-1027d1fab9bf	6b36979a-fbea-4843-a832-85e8509a7d90	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
cd94aaf6-3351-482a-92c3-9bd5506de5ca	8bca5777-8762-40d2-a2f4-7c437a106df1	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
374fde6b-5efd-46c3-bcb9-a58aa104c49a	4160714b-10ca-4c4f-8b8a-d4c2cba53724	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
89896c30-4478-4112-9c8c-86ccf52aedf0	54e23930-a575-4bef-b0d1-7b8584a0b011	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
b05abb72-327f-49c0-b47e-db697a1835e2	355d16bb-9d61-4ed9-991e-66e0cae3d29e	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
9265a025-0c46-4d81-bbaf-7022eb4010f0	eef3b439-112e-485e-a7b6-0d7cd40198bf	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
45c956ae-00cd-4ec5-8929-a32a4be56ffb	ba286914-b27e-4b33-980d-9e768e8b6569	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
d26587a0-2afb-46d1-9b17-394575f76f14	836aa0a0-092c-4a2c-9982-7a2f5deb4880	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
c09013d9-ef6d-44df-853b-02a6bdafd70d	ad312dc8-07cc-4429-ab36-054466502320	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
1968a5c8-218a-4252-950e-39df6618f36d	5a1e5f5e-1d22-41f4-a3d1-cfec49e83974	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
f2c340c8-ea99-4fc8-9188-983e30929093	c5d4a6af-58c5-49e4-9dbd-e2af0360e0c0	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
736531aa-8525-43bc-8472-17ab72416b14	6417f382-7e3a-4884-a852-bc06176f6848	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
f5f97f0d-c5cb-4052-84f1-b4f4cf7d0bfc	3cc363fc-99c1-4779-806b-e6d10019e507	ebb5f404-2267-4fa1-bd71-dd9e54707294	0.200
07e91cbd-eb9b-47dc-a8fb-a8df283d1383	d725ab54-f42b-41c9-9da6-fd327076f301	e4af9701-0d10-404a-9371-a0e7c84ec8f1	0.270
b50a907d-4809-4fb7-85c5-c3deb8fa83e9	59a3f6b4-9692-439f-ba35-8c9211bbff90	8353e03f-35a0-44f9-ad7a-5c4336f90725	0.250
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
\.


--
-- Data for Name: stock_articles; Type: TABLE DATA; Schema: public; Owner: caisse_user
--

COPY public.stock_articles (id, name, category, unit, out_mode, quantity, avg_cost_xof, alert_threshold, is_active, note, created_at, updated_at) FROM stdin;
07ee94bb-1c62-4d20-b9e3-9b2aa9132f4a	Poulet pondeuse	PROTEINE	pièce	RECIPE	0.000	4000.00	\N	t	\N	2026-10-20 15:03:14.515927+00	2026-10-20 15:03:14.515936+00
6a7dc7ed-7a51-4954-9d06-68b9bd08d74c	Eau Celeste 0,5 L	BOISSON	bouteille	RECIPE	7.000	111.11	\N	t	\N	2026-10-20 15:03:14.558718+00	2026-10-20 15:03:14.564363+00
6860e5c8-8643-46d2-a6e9-bfe6e9fc80a0	Eau Celeste 1,5 L	BOISSON	bouteille	RECIPE	12.000	266.66	\N	t	\N	2026-10-20 15:03:14.565711+00	2026-10-20 15:03:14.570024+00
0edc867d-1dfa-4bdc-8988-8401299297b9	Sucrerie bouteille 33 cl	BOISSON	bouteille	RECIPE	24.000	187.50	\N	t	\N	2026-10-20 15:03:14.571148+00	2026-10-20 15:03:14.576071+00
fb615c0d-0da1-44bb-9a49-c1e3a3d772b2	Canette sucrerie (mélange)	BOISSON	canette	RECIPE	6.000	300.00	\N	t	\N	2026-10-20 15:03:14.577423+00	2026-10-20 15:03:14.582315+00
b9e7f197-7df5-4ffd-ab80-e033bfe823bd	Canette Ivorio	BOISSON	canette	RECIPE	1.000	583.33	\N	t	\N	2026-10-20 15:03:14.583686+00	2026-10-20 15:03:14.588952+00
9c44e792-4724-46eb-a278-875e6ce514a8	Orangina 50 cl	BOISSON	bouteille	RECIPE	0.000	416.70	\N	t	\N	2026-10-20 15:03:14.590811+00	2026-10-20 15:03:14.59082+00
21c0a4c6-64c9-4223-a0c3-fee4ef7ebd1f	Canette Cody's	BOISSON	canette	RECIPE	6.000	404.20	\N	t	\N	2026-10-20 15:03:14.596034+00	2026-10-20 15:03:14.601266+00
2cad3fbe-c8cf-4dc8-9a9c-3c39831d69e1	Jus de gingembre	BOISSON	bouteille	RECIPE	120.000	333.30	\N	t	\N	2026-10-20 15:03:14.602509+00	2026-10-20 15:03:14.608284+00
d9fbe76f-9256-4c7e-9f98-5f9a1f4b0c3d	Jus de bissap	BOISSON	bouteille	RECIPE	96.000	250.00	\N	t	\N	2026-10-20 15:03:14.609452+00	2026-10-20 15:03:14.614161+00
c3165735-9157-4879-b272-a6807c36d677	Jus Tomy	BOISSON	bouteille	RECIPE	62.000	250.00	\N	t	\N	2026-10-20 15:03:14.615222+00	2026-10-20 15:03:14.619766+00
25fd53a8-c277-418d-a596-b575ce7f784a	Jus de passion	BOISSON	bouteille	RECIPE	131.000	400.00	\N	t	\N	2026-10-20 15:03:14.627718+00	2026-10-20 15:03:14.632964+00
edba16c2-09c9-47b2-977e-82d92a6b0582	Lait / dêguê	BOISSON	bouteille	RECIPE	9.000	800.00	\N	t	\N	2026-10-20 15:03:14.634105+00	2026-10-20 15:03:14.639542+00
8ca7f94b-d3d9-4a5e-860b-6a500b0d3502	Capsule café expresso	BOISSON	capsule	RECIPE	6.000	200.00	\N	t	\N	2026-10-20 15:03:14.641906+00	2026-10-20 15:03:14.647798+00
bb8d7b4b-59c0-4e18-beb7-1b2862157061	Riz	EPICERIE	kg	INVENTORY	0.000	640.00	\N	t	\N	2026-10-20 15:03:14.649156+00	2026-10-20 15:03:14.649164+00
86c3f5af-81ec-4e55-86dd-9ec82033a69e	Couscous	EPICERIE	kg	INVENTORY	0.000	800.00	\N	t	\N	2026-10-20 15:03:14.654804+00	2026-10-20 15:03:14.654814+00
a92dd8ce-2c2f-46a0-9841-21082770840a	Pomme de terre	EPICERIE	kg	INVENTORY	0.000	520.00	\N	t	\N	2026-10-20 15:03:14.658748+00	2026-10-20 15:03:14.658757+00
c656b6a5-29d0-4e05-a85a-beb25e986bc4	Oignon	EPICERIE	kg	INVENTORY	0.000	400.00	\N	t	\N	2026-10-20 15:03:14.662034+00	2026-10-20 15:03:14.662043+00
7eb839f2-bc73-4b36-b971-9ed13a5bddd3	Oignon violet	EPICERIE	kg	INVENTORY	0.000	700.00	\N	t	\N	2026-10-20 15:03:14.665307+00	2026-10-20 15:03:14.665315+00
6ba11eee-ba07-4a0e-b6e9-e3c43f76d328	Igname	EPICERIE	kg	INVENTORY	0.000	667.00	\N	t	\N	2026-10-20 15:03:14.668591+00	2026-10-20 15:03:14.668599+00
6f0d0280-57dc-4d8f-93b4-a2f20c3bdcf1	Tomate	EPICERIE	kg	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.671746+00	2026-10-20 15:03:14.671753+00
8ea90fe3-d7e3-4186-a5db-d459dc24d98d	Tomate en pâte	EPICERIE	boîte	INVENTORY	0.000	2250.00	\N	t	4 500 en avril	2026-10-20 15:03:14.675308+00	2026-10-20 15:03:14.675316+00
4ed510c1-89a1-4d6e-a0ee-3b3ccdcbe5f3	Attiéké	EPICERIE	boule	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.678444+00	2026-10-20 15:03:14.678452+00
0357a4f3-4c06-4275-9264-c70a25c374c1	Banane alloco	EPICERIE	régime	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.681601+00	2026-10-20 15:03:14.681609+00
90f3fed1-d9d3-4cdc-8651-c32bdb195963	Banane plantain (foufou)	EPICERIE	régime	INVENTORY	0.000	5000.00	\N	t	\N	2026-10-20 15:03:14.684771+00	2026-10-20 15:03:14.684778+00
08cb25bf-cdde-4549-9392-f4bf2a9d2909	Manioc	EPICERIE	kg	INVENTORY	0.000	1500.00	\N	t	500 en avril	2026-10-20 15:03:14.687907+00	2026-10-20 15:03:14.687914+00
cacb80fe-d0f9-4801-b6c6-fefe8703dd50	Ail	EPICERIE	kg	INVENTORY	0.000	1500.00	\N	t	\N	2026-10-20 15:03:14.691586+00	2026-10-20 15:03:14.691593+00
658b4aa4-8cd2-4a1e-8b42-fe19c5f38073	Carotte	EPICERIE	kg	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.694727+00	2026-10-20 15:03:14.694734+00
91655ec4-b706-4fbe-a456-308fb82a5f42	Aubergine	EPICERIE	kg	INVENTORY	0.000	300.00	\N	t	\N	2026-10-20 15:03:14.697786+00	2026-10-20 15:03:14.697794+00
0e520485-53a3-403a-8dc8-547417bb83e4	Carpe	PROTEINE	pièce	RECIPE	20.000	960.00	\N	t	\N	2026-10-20 15:03:14.546725+00	2026-10-22 16:47:00.523351+00
5e5c8e90-160b-4766-abc5-0b06087c6456	Faux saumon	PROTEINE	morceau	RECIPE	21.000	500.00	\N	t	acheté entier à 2 500 F jusqu'en août, au morceau depuis	2026-10-20 15:03:14.538035+00	2026-10-22 16:47:00.523369+00
80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	Loss	PROTEINE	pièce	RECIPE	30.500	556.00	\N	t	0,5 poisson par plat observé	2026-10-20 15:03:14.551663+00	2026-10-22 16:47:00.523373+00
e4af9701-0d10-404a-9371-a0e7c84ec8f1	Mouton	PROTEINE	kg	RECIPE	18.000	5500.00	\N	t	\N	2026-10-20 15:03:14.45145+00	2026-10-22 16:47:00.523383+00
ebb5f404-2267-4fa1-bd71-dd9e54707294	Bœuf	PROTEINE	kg	RECIPE	10.000	4000.00	\N	t	fournisseur M. Yapi (4 000 F/kg)	2026-10-20 15:03:14.46386+00	2026-10-22 16:47:00.523386+00
258570a6-aee0-4adb-a7e1-526f56b06506	Faux brochet	PROTEINE	pièce	RECIPE	31.000	800.00	\N	t	\N	2026-10-20 15:03:14.522143+00	2026-10-22 19:10:58.628802+00
54d0c628-235d-4f09-b026-ab073c650261	Jus de citron	BOISSON	bouteille	RECIPE	15.000	250.00	\N	t	\N	2026-10-20 15:03:14.620855+00	2026-10-22 19:11:12.27298+00
8353e03f-35a0-44f9-ad7a-5c4336f90725	Poulet	PROTEINE	pièce	RECIPE	41.250	3000.00	\N	t	\N	2026-10-20 15:03:14.506861+00	2026-10-22 19:11:12.272992+00
a4cbfa56-e146-4cec-b536-34c376c34e28	Sosso	PROTEINE	pièce	RECIPE	17.000	1540.00	\N	t	\N	2026-10-20 15:03:14.531033+00	2026-10-22 19:11:12.272995+00
8161cf8a-5c27-4f7e-a46e-be18f876a61e	Chou	EPICERIE	pièce	INVENTORY	0.000	700.00	\N	t	\N	2026-10-20 15:03:14.700866+00	2026-10-20 15:03:14.700872+00
e7c0a607-ae01-4648-86cd-74b12a91e834	Navet	EPICERIE	kg	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.704592+00	2026-10-20 15:03:14.704606+00
77136ac2-37cc-4d12-9ff4-95a07afeeb46	Courgette	EPICERIE	kg	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.710146+00	2026-10-20 15:03:14.710156+00
bd4c5793-fb0b-4f57-adf4-7a9c98df4473	Poivron	EPICERIE	kg	INVENTORY	0.000	1300.00	\N	t	\N	2026-10-20 15:03:14.713708+00	2026-10-20 15:03:14.713714+00
42295a23-2514-4477-be0b-a8491aa6d3c9	Haricot vert	EPICERIE	kg	INVENTORY	0.000	1500.00	\N	t	\N	2026-10-20 15:03:14.716757+00	2026-10-20 15:03:14.716765+00
1cae06ac-04d4-4d22-a52d-487e50268463	Petit pois	EPICERIE	boîte	INVENTORY	0.000	2000.00	\N	t	\N	2026-10-20 15:03:14.720127+00	2026-10-20 15:03:14.720135+00
c23a7da5-5358-4a87-bb97-981a779f3e34	Salade	EPICERIE	pièce	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.723826+00	2026-10-20 15:03:14.723836+00
fb04ec54-f6d9-49d8-ab2c-d58903c53471	Concombre	EPICERIE	pièce	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.727444+00	2026-10-20 15:03:14.727452+00
78c049e1-b3e5-4e52-8d22-b2741a9016de	Gombo	EPICERIE	tas	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.730943+00	2026-10-20 15:03:14.730951+00
c36db8db-6827-4e54-8bfc-9c863d691b44	Gombo de kopè	EPICERIE	tas	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.734212+00	2026-10-20 15:03:14.734222+00
4955cd40-1990-4117-9970-679efe21a6aa	Feuille de dah	EPICERIE	tas	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.73739+00	2026-10-20 15:03:14.737397+00
888b71eb-baa9-42c4-baa1-fc5ee188b1b1	Épinard	EPICERIE	tas	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.74104+00	2026-10-20 15:03:14.741049+00
c8128150-354d-4a2b-904a-f8b5841f9b9b	Feuille oignon, persil, poireau	EPICERIE	tas	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.744229+00	2026-10-20 15:03:14.744237+00
66fd45cd-cfbf-480d-aa61-a86a19e0b536	Assaisonnement vert	EPICERIE	tas	INVENTORY	0.000	150.00	\N	t	\N	2026-10-20 15:03:14.747304+00	2026-10-20 15:03:14.747312+00
fa786d22-6359-4d07-8fbb-0a1c15871741	Graine de palme	EPICERIE	kg	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.750614+00	2026-10-20 15:03:14.750622+00
aeacf1df-c17b-4055-9fd5-204dac99c2fd	Pâte d'arachide	EPICERIE	kg	INVENTORY	0.000	3500.00	\N	t	1 500 en avril	2026-10-20 15:03:14.753572+00	2026-10-20 15:03:14.75358+00
de94d296-4c58-42ff-920b-691baab6902d	Pistache	EPICERIE	kg	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.756914+00	2026-10-20 15:03:14.756924+00
f466a03f-6e7a-4557-a90b-07b623eb529c	Huile	EPICERIE	litre	INVENTORY	0.000	1060.00	\N	t	\N	2026-10-20 15:03:14.760185+00	2026-10-20 15:03:14.760213+00
2185f501-e5d2-467a-a562-ec093dce56a9	Huile rouge	EPICERIE	litre	INVENTORY	0.000	2000.00	\N	t	\N	2026-10-20 15:03:14.763115+00	2026-10-20 15:03:14.763123+00
98fa99bd-50a1-4767-a147-f0a77cdbf912	Poivre	EPICERIE	kg	INVENTORY	0.000	3500.00	\N	t	\N	2026-10-20 15:03:14.766139+00	2026-10-20 15:03:14.766146+00
c5ce6682-51d4-443f-bb2f-fda4a32b0cb1	Piment	EPICERIE	tas	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.7693+00	2026-10-20 15:03:14.769307+00
2b2efe1b-6b47-4228-9508-82c43be96592	Piment garba	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.772427+00	2026-10-20 15:03:14.772435+00
02a19865-af2d-466d-9754-363c10dcda24	Piment sénbon	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.776119+00	2026-10-20 15:03:14.776128+00
2e397e12-f4b0-4c25-96af-63ea19feb790	Piment en poudre	EPICERIE	sachet	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.779174+00	2026-10-20 15:03:14.779181+00
acf15bb3-a9c2-4d50-b450-9001cbda285e	Poisson sec	EPICERIE	kg	INVENTORY	0.000	667.00	\N	t	deux lignes dans l'Excel (143 et 667)	2026-10-20 15:03:14.782278+00	2026-10-20 15:03:14.782285+00
cb9130fc-ac18-4530-acf5-2db2641753f3	Poisson fumé (foufou)	EPICERIE	kg	INVENTORY	0.000	10000.00	\N	t	\N	2026-10-20 15:03:14.785377+00	2026-10-20 15:03:14.785385+00
26290d66-6767-41d8-ba7e-40916c397c90	Poisson frais (foufou)	EPICERIE	kg	INVENTORY	0.000	10000.00	\N	t	\N	2026-10-20 15:03:14.788574+00	2026-10-20 15:03:14.788583+00
4a635e05-20c0-4a7b-b7a9-d531fa89ff4a	Viande (foufou)	EPICERIE	kg	INVENTORY	0.000	4500.00	\N	t	\N	2026-10-20 15:03:14.792468+00	2026-10-20 15:03:14.792477+00
f62f58d8-b821-4425-8d60-e8d8dfa160d2	Tripe	EPICERIE	kg	INVENTORY	0.000	2000.00	\N	t	\N	2026-10-20 15:03:14.795819+00	2026-10-20 15:03:14.795828+00
7966dbe5-910e-4b4b-8ecb-5c3ba231ddd1	Tête de bœuf	EPICERIE	pièce	INVENTORY	0.000	1500.00	\N	t	\N	2026-10-20 15:03:14.798878+00	2026-10-20 15:03:14.798887+00
6e90a97b-a674-47f8-ad60-5f54335f9c54	Crabe	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.802132+00	2026-10-20 15:03:14.802141+00
08216391-c95a-4a63-a95a-36d808801419	Crevette sèche	EPICERIE	sachet	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.805323+00	2026-10-20 15:03:14.805331+00
91e267ee-ce06-4737-b297-5c8ba510f986	Magne fumé	EPICERIE	pièce	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.809273+00	2026-10-20 15:03:14.809282+00
a60a863f-69b3-4b5e-a240-ebe1b9f31728	Magne sec	EPICERIE	pièce	INVENTORY	0.000	15.00	\N	t	\N	2026-10-20 15:03:14.812306+00	2026-10-20 15:03:14.812313+00
ba4a683e-f3b6-4d87-a415-a9b83d57ec2a	Djoumgblé	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.815373+00	2026-10-20 15:03:14.815381+00
ab69a04c-8b53-4b94-8620-ad36447574a2	Soumbara	EPICERIE	kg	INVENTORY	0.000	5000.00	\N	t	\N	2026-10-20 15:03:14.81837+00	2026-10-20 15:03:14.818378+00
7e10c02e-5781-4bf1-8b6c-237a8085f663	Akpi	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.821379+00	2026-10-20 15:03:14.821386+00
031058df-6ea2-4838-b0d8-91662194502d	Fèfè	EPICERIE	tas	INVENTORY	0.000	2000.00	\N	t	\N	2026-10-20 15:03:14.824896+00	2026-10-20 15:03:14.824906+00
c65a626e-991a-4bfa-85a8-b7d23cd364c0	Kplo	EPICERIE	tas	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.827895+00	2026-10-20 15:03:14.827904+00
7c1d3f7d-dcab-46e0-89b7-a2e0154f4d37	Yet	EPICERIE	pièce	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.830837+00	2026-10-20 15:03:14.830845+00
9ba95d7c-7efc-4521-9aba-6b401c7223f0	Djet	EPICERIE	pièce	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.833717+00	2026-10-20 15:03:14.833724+00
5deeb776-8c5f-48ec-9ef7-c55f2d51d15d	Poudre de maïs	EPICERIE	kg	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.836613+00	2026-10-20 15:03:14.836622+00
ce3aea34-ecd0-4f58-bd2b-9716b768e513	Farine pâtissière	EPICERIE	kg	INVENTORY	0.000	700.00	\N	t	\N	2026-10-20 15:03:14.840065+00	2026-10-20 15:03:14.840076+00
d1a4136a-5831-4b23-8438-d6f5f15f84fc	Œuf	EPICERIE	pièce	INVENTORY	0.000	84.00	\N	t	\N	2026-10-20 15:03:14.843385+00	2026-10-20 15:03:14.843392+00
ba1434e3-3dfc-4aec-9d38-c1e459c2b16e	Pain	EPICERIE	pièce	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.845963+00	2026-10-20 15:03:14.84597+00
b8d83cb4-cc9b-4bd1-8763-c6a92eff551c	Fruits	EPICERIE	tas	INVENTORY	0.000	1000.00	\N	t	\N	2026-10-20 15:03:14.848443+00	2026-10-20 15:03:14.84845+00
083f2621-ca1f-44a5-9ad1-df1debb076c4	Citron / thé	EPICERIE	sachet	INVENTORY	0.000	500.00	\N	t	\N	2026-10-20 15:03:14.851187+00	2026-10-20 15:03:14.851227+00
6cd46f2c-73ef-4ed0-a1d6-8be26e1eea13	Mayonnaise	EPICERIE	pot	INVENTORY	0.000	2300.00	\N	t	\N	2026-10-20 15:03:14.854179+00	2026-10-20 15:03:14.854186+00
c2e33d74-f331-415d-bfeb-7c42f66e0296	Moutarde	EPICERIE	pot	INVENTORY	0.000	1400.00	\N	t	\N	2026-10-20 15:03:14.85795+00	2026-10-20 15:03:14.857959+00
0d45efe2-2e7f-4d3c-a266-7bb742479fac	Vinaigre blanc	EPICERIE	bouteille	INVENTORY	0.000	750.00	\N	t	\N	2026-10-20 15:03:14.860946+00	2026-10-20 15:03:14.860953+00
d4d263e4-aefa-4d09-bbbc-ba1edc1fb6d9	Vinaigre rouge	EPICERIE	bouteille	INVENTORY	0.000	750.00	\N	t	\N	2026-10-20 15:03:14.864021+00	2026-10-20 15:03:14.864029+00
58cbdd9d-2474-4085-9907-8e11f91d8b12	Maggi tablette	EPICERIE	cube	INVENTORY	0.000	26.70	\N	t	\N	2026-10-20 15:03:14.867098+00	2026-10-20 15:03:14.867107+00
bf9af96c-7222-4983-a8eb-2315a26543be	Maggi poulet	EPICERIE	cube	INVENTORY	0.000	26.70	\N	t	\N	2026-10-20 15:03:14.870142+00	2026-10-20 15:03:14.87015+00
b03a9aca-f913-4695-b910-95872ec2d660	Maggi crevette	EPICERIE	cube	INVENTORY	0.000	26.70	\N	t	\N	2026-10-20 15:03:14.873328+00	2026-10-20 15:03:14.873337+00
33d39945-93b2-4199-bd3c-519cfc8c5e39	Chapelet de maggi	EPICERIE	chapelet	INVENTORY	0.000	50.00	\N	t	\N	2026-10-20 15:03:14.876758+00	2026-10-20 15:03:14.876766+00
21ee85c8-23cd-4276-8094-56e001b97b51	Doli poulet	EPICERIE	sachet	INVENTORY	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.880144+00	2026-10-20 15:03:14.880151+00
5282250a-6c57-4708-a889-44d594c6875c	Djonké	EPICERIE	sachet	INVENTORY	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.883652+00	2026-10-20 15:03:14.88366+00
fd84ec0f-4272-49af-a43d-a26ff87ec313	Adja rouge	EPICERIE	sachet	INVENTORY	0.000	250.00	\N	t	\N	2026-10-20 15:03:14.887542+00	2026-10-20 15:03:14.887551+00
0b8c3163-f9d3-4663-8308-acb9cc33130b	Adja marron	EPICERIE	sachet	INVENTORY	0.000	150.00	\N	t	\N	2026-10-20 15:03:14.891802+00	2026-10-20 15:03:14.891813+00
f1b1bd4d-2444-4dc3-a02b-d2e38bd81551	Aromate bouillon	EPICERIE	sachet	INVENTORY	0.000	100.00	\N	t	\N	2026-10-20 15:03:14.896046+00	2026-10-20 15:03:14.896057+00
e4f32563-95ac-4528-9343-e44e7a0e34b9	Colorant alimentaire	EPICERIE	sachet	INVENTORY	0.000	15.00	\N	t	\N	2026-10-20 15:03:14.899722+00	2026-10-20 15:03:14.89973+00
f412fad2-4aff-4442-8be9-ab65399d351d	Gaz	ENERGIE	bouteille	INVENTORY	0.000	14500.00	\N	t	\N	2026-10-20 15:03:14.903192+00	2026-10-20 15:03:14.903231+00
dde345c3-3925-4746-a81a-998b450b5f75	Take away	EMBALLAGE	pièce	INVENTORY	0.000	60.00	\N	t	\N	2026-10-20 15:03:14.907127+00	2026-10-20 15:03:14.907137+00
5235869f-45bb-4a01-8c03-d0973987cdaf	Bol de sauce	EMBALLAGE	pièce	INVENTORY	0.000	70.00	\N	t	\N	2026-10-20 15:03:14.910651+00	2026-10-20 15:03:14.910659+00
84f5ad21-a829-4a60-b575-e24a5e92cd45	Cuillère + fourchette	EMBALLAGE	paire	INVENTORY	0.000	10.00	\N	t	20 en avril	2026-10-20 15:03:14.914121+00	2026-10-20 15:03:14.914129+00
d09d64f4-764e-4c6f-9cc5-232cb6e9f12d	Sachet	EMBALLAGE	paquet	INVENTORY	0.000	3000.00	\N	t	\N	2026-10-20 15:03:14.917647+00	2026-10-20 15:03:14.917655+00
2dfae7b6-8af0-481e-972f-d13c7d139ffd	Papier aluminium 3x50 m	EMBALLAGE	rouleau	INVENTORY	0.000	2650.00	\N	t	\N	2026-10-20 15:03:14.92109+00	2026-10-20 15:03:14.9211+00
47cf42cf-ed12-4072-a987-896474d9dfe1	Allumettes	EMBALLAGE	boîte	INVENTORY	0.000	166.60	\N	t	\N	2026-10-20 15:03:14.924978+00	2026-10-20 15:03:14.924986+00
5f7d46d7-7076-4470-bec7-543b954b10ec	Papier mouchoir	ENTRETIEN	paquet	INVENTORY	0.000	1988.00	\N	t	\N	2026-10-20 15:03:14.927912+00	2026-10-20 15:03:14.927921+00
c920af02-d2a9-45c2-865e-0a762ab89060	Essuie-tout	ENTRETIEN	rouleau	INVENTORY	0.000	566.66	\N	t	\N	2026-10-20 15:03:14.931039+00	2026-10-20 15:03:14.931047+00
10ac2feb-5520-4cf3-8e51-1e497e0a8a3c	Papier hygiénique	ENTRETIEN	paquet	INVENTORY	0.000	4100.00	\N	t	\N	2026-10-20 15:03:14.934185+00	2026-10-20 15:03:14.93422+00
0256ce42-3b91-4444-a638-5470e036ac71	Sac poubelle	ENTRETIEN	pièce	INVENTORY	0.000	200.00	\N	t	\N	2026-10-20 15:03:14.937648+00	2026-10-20 15:03:14.937657+00
7c9061ac-2a1d-4ff0-8680-75339e8917a4	Javel 8° 3 L	ENTRETIEN	bidon	INVENTORY	0.000	1366.60	\N	t	\N	2026-10-20 15:03:14.941623+00	2026-10-20 15:03:14.941633+00
f4b8119b-3431-4050-8c18-e8f9bf560a79	Javel 12° 3 L	ENTRETIEN	bidon	INVENTORY	0.000	1700.00	\N	t	\N	2026-10-20 15:03:14.945244+00	2026-10-20 15:03:14.945252+00
be80260f-fc61-4ff9-a7d5-9845b9dd861c	Savon liquide 3 L	ENTRETIEN	bidon	INVENTORY	0.000	1983.30	\N	t	\N	2026-10-20 15:03:14.948748+00	2026-10-20 15:03:14.948755+00
83dd5b03-3ab9-415f-a098-27a23a019245	Insecticide	ENTRETIEN	bombe	INVENTORY	0.000	812.50	\N	t	\N	2026-10-20 15:03:14.95224+00	2026-10-20 15:03:14.952248+00
71e8714d-dbf6-4323-ad9b-dadada8892f5	Chapeau de cuisine	ENTRETIEN	pièce	INVENTORY	0.000	35.00	\N	t	\N	2026-10-20 15:03:14.955755+00	2026-10-20 15:03:14.955766+00
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
72a5e9f8-1510-4dd5-9178-3eff858f1a26	e4af9701-0d10-404a-9371-a0e7c84ec8f1	OPENING	8.000	8.000	5500.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.454507+00
54a11566-c921-452d-86a7-7f78d78732d9	ebb5f404-2267-4fa1-bd71-dd9e54707294	OPENING	0.000	0.000	4000.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.503992+00
0788ef75-7949-4e0f-b0a7-1d2740958224	8353e03f-35a0-44f9-ad7a-5c4336f90725	OPENING	1.500	1.500	3000.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.510845+00
fe30ec9d-93df-4309-b321-18d4591ccc51	07ee94bb-1c62-4d20-b9e3-9b2aa9132f4a	OPENING	0.000	0.000	4000.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.519595+00
f7d6c339-3af5-418f-a38e-f6db738659de	258570a6-aee0-4adb-a7e1-526f56b06506	OPENING	22.000	22.000	800.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.52645+00
cf4130d6-f184-4a0f-aec4-541750d5b9e9	a4cbfa56-e146-4cec-b536-34c376c34e28	OPENING	8.000	8.000	1540.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.534475+00
07cd59b6-e143-4bb0-a9d2-82f69688642c	5e5c8e90-160b-4766-abc5-0b06087c6456	OPENING	1.000	1.000	500.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.542601+00
68d5d2fe-791d-4e58-8280-c547203d88c7	0e520485-53a3-403a-8dc8-547417bb83e4	OPENING	0.000	0.000	960.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.549482+00
1882daba-f1ff-4573-816e-b992e2e96ae1	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	OPENING	0.500	0.500	556.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.554273+00
acc936c1-2978-4710-81f3-8930114cd245	6a7dc7ed-7a51-4954-9d06-68b9bd08d74c	OPENING	7.000	7.000	111.11	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.561926+00
2b4b44dd-1e90-4896-968a-4eeca396734f	6860e5c8-8643-46d2-a6e9-bfe6e9fc80a0	OPENING	12.000	12.000	266.66	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.568188+00
145dcf04-6e8b-44d8-9e39-07e6fb8e6336	0edc867d-1dfa-4bdc-8988-8401299297b9	OPENING	24.000	24.000	187.50	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.57399+00
6186b319-1156-4c81-897b-66e74a4faa1f	fb615c0d-0da1-44bb-9a49-c1e3a3d772b2	OPENING	6.000	6.000	300.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.580234+00
559cd332-f8a5-4f06-8681-a916980d1e04	b9e7f197-7df5-4ffd-ab80-e033bfe823bd	OPENING	1.000	1.000	583.33	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.586689+00
080e712b-aa50-4d17-9c19-390d8cc09793	9c44e792-4724-46eb-a278-875e6ce514a8	OPENING	0.000	0.000	416.70	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.593846+00
4f4cdb29-e111-46fc-baa6-1227e72404d7	21c0a4c6-64c9-4223-a0c3-fee4ef7ebd1f	OPENING	6.000	6.000	404.20	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.59889+00
ad645c1a-14ae-423c-b15f-74516b12cb1d	2cad3fbe-c8cf-4dc8-9a9c-3c39831d69e1	OPENING	120.000	120.000	333.30	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.605595+00
17fafc08-03ee-4967-bb47-396743f5fdcb	d9fbe76f-9256-4c7e-9f98-5f9a1f4b0c3d	OPENING	96.000	96.000	250.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.612052+00
097fc3aa-88b0-4653-a78e-6976031da276	c3165735-9157-4879-b272-a6807c36d677	OPENING	62.000	62.000	250.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.617835+00
8b2e7b7d-39d2-4f12-8fa4-967ca148f18b	54d0c628-235d-4f09-b026-ab073c650261	OPENING	16.000	16.000	250.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.623947+00
6f2211bc-f2b3-446b-a333-668c576c223a	25fd53a8-c277-418d-a596-b575ce7f784a	OPENING	131.000	131.000	400.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.630595+00
d6805052-5b7b-4e69-826f-86e50295c6ae	edba16c2-09c9-47b2-977e-82d92a6b0582	OPENING	9.000	9.000	800.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.637305+00
e76d58d5-280b-445e-8511-bb48d8a79fc9	8ca7f94b-d3d9-4a5e-860b-6a500b0d3502	OPENING	6.000	6.000	200.00	2026-10-20	\N	\N	\N	Reprise du stock Excel du 13/10/2026	\N	2026-10-20 15:03:14.645304+00
f430daf0-ee3a-4774-9ab8-c9e98a9f83a6	ebb5f404-2267-4fa1-bd71-dd9e54707294	PURCHASE_IN	10.000	10.000	4000.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.534916+00
8754903c-a5df-4886-97f1-887c737ca202	0e520485-53a3-403a-8dc8-547417bb83e4	PURCHASE_IN	20.000	20.000	960.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.534934+00
91a5d241-8252-4f06-a367-75ddd15482ba	258570a6-aee0-4adb-a7e1-526f56b06506	PURCHASE_IN	10.000	32.000	800.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.53494+00
ff99f49c-337a-47c1-a619-06ef9e07921e	5e5c8e90-160b-4766-abc5-0b06087c6456	PURCHASE_IN	20.000	21.000	500.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.534947+00
6cbe4a09-d55c-455d-bd9d-9f1625125c16	80e2eb7d-64eb-48fe-b27b-8a2f87dd077b	PURCHASE_IN	30.000	30.500	556.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.534953+00
f69baadd-a228-46cc-aff8-b2fe1c8dbd02	e4af9701-0d10-404a-9371-a0e7c84ec8f1	PURCHASE_IN	10.000	18.000	5500.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.534961+00
b02df634-795a-40b8-a732-00d5f99bc1c9	8353e03f-35a0-44f9-ad7a-5c4336f90725	PURCHASE_IN	20.000	21.500	3000.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.534967+00
4726547d-57a9-4064-a145-fbf58e01e4c6	8353e03f-35a0-44f9-ad7a-5c4336f90725	PURCHASE_IN	20.000	41.500	3000.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.534974+00
f3e2ba29-5a18-4802-8e60-313e7488e255	a4cbfa56-e146-4cec-b536-34c376c34e28	PURCHASE_IN	10.000	18.000	1540.00	2026-10-22	\N	\N	\N	Achats marché #2026-10-22	4b5224bf-057a-4654-b13e-0e65ff403161	2026-10-22 16:47:00.53498+00
92ae0f84-1691-41ba-9747-02140a68651e	258570a6-aee0-4adb-a7e1-526f56b06506	SALE_OUT	-1.000	31.000	800.00	2026-10-22	9d70470c-a448-4666-8a3b-26a894e407ad	79bb649e-ad5c-4cfe-be65-85b53215f00e	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22 19:10:58.589552+00
6f5a0df1-a8b0-4329-b89c-135d7a526004	8353e03f-35a0-44f9-ad7a-5c4336f90725	SALE_OUT	-0.250	41.250	3000.00	2026-10-22	c259aa5a-5c56-48e4-af2d-2cd301af43d8	560b9dd9-c883-4328-aeb8-26747f369ea8	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22 19:11:12.259339+00
d0dd4612-d92f-423c-b5bc-d8489b4c6109	a4cbfa56-e146-4cec-b536-34c376c34e28	SALE_OUT	-1.000	17.000	1540.00	2026-10-22	c259aa5a-5c56-48e4-af2d-2cd301af43d8	e5045925-ac9d-483b-b04c-b25422fd2a1d	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22 19:11:12.259702+00
2437e45b-ccdb-4eae-9963-755befb8a99d	54d0c628-235d-4f09-b026-ab073c650261	SALE_OUT	-1.000	15.000	250.00	2026-10-22	c259aa5a-5c56-48e4-af2d-2cd301af43d8	088e8d7e-74e3-4e9a-8336-71bc26eb87d6	\N	\N	5d9ffecd-87a5-47ff-80c4-f9c1c457293c	2026-10-22 19:11:12.259837+00
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
695652d7-7ab3-4b5d-a001-d4096cb849a0	Responsable Restaurant	$argon2id$v=19$m=65536,t=3,p=4$frm0zYKSbZ10S7eGqRBqxQ$xchoZhabdN6xP/rEAizxamDgNS05L3K8QfC15xqSBfA	RESPONSABLE	t	0	\N	2026-10-22 11:15:43.964517+00	2026-10-03 16:12:32.906777+00	2026-10-22 11:15:43.989234+00
4b5224bf-057a-4654-b13e-0e65ff403161	Administrateur	$argon2id$v=19$m=65536,t=3,p=4$GqJWVRaBv6eGu1kK+Ow9lQ$ZEtbcvnGxvrCqOuCC7nIXxyvb3Zq3tGfMms1mHsJeH0	ADMIN	t	0	\N	2026-10-23 11:32:04.877504+00	2026-10-03 16:12:32.997768+00	2026-10-23 11:32:04.890964+00
5d9ffecd-87a5-47ff-80c4-f9c1c457293c	Digui Thio	$argon2id$v=19$m=65536,t=3,p=4$Md97/XbvbaCwLFqYZ1daDg$UKqWC3skjutOFFNxDGntbhuqF2Sxr/sAjLisKi1LCfQ	CAISSIER	t	0	\N	2026-10-23 11:54:49.64288+00	2026-10-03 16:12:32.820964+00	2026-10-23 11:54:49.654702+00
a3e01053-c2ad-4631-910a-0eb48345e5b1	Économe Marché	$argon2id$v=19$m=65536,t=3,p=4$Xz1gQHDZuL6WVpHFWzJ9oA$ir489NrBIBaNracEmQFfmuY+7wfjSAx1sFY3rBSos9U	ECONOME	t	0	\N	2026-10-23 11:57:21.956617+00	2026-10-22 10:56:08.7902+00	2026-10-23 11:57:21.966626+00
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

\unrestrict jdveLgCcTpUNGdMQ2JjqTPy2aBcLaT2y0N6Gb0K4Ldu4KP23Ba0riq2wdVDut3g

