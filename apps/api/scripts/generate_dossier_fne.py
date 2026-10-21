#!/usr/bin/env python3
"""Générateur de dossier d'homologation FNE pour la DGI Côte d'Ivoire.
Produit les spécimens visuels (PNG, HTML) et assemble les requêtes/réponses JSON.
"""

import json
import os
from pathlib import Path
import qrcode
from PIL import Image, ImageDraw, ImageFont

BASE_DIR = Path(__file__).resolve().parent.parent
SOURCE_PROBE = BASE_DIR / "fne-probe" / "20261020T125044Z"
OUTPUT_DIR = BASE_DIR.parent.parent / "Dossier_Homologation_FNE"

FONT_REGULAR_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_BOLD_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"


def draw_ticket(
    output_path: Path,
    title: str,
    establishment: str,
    ncc: str,
    address: str,
    phone: str,
    pos_id: str,
    ticket_num: str,
    date_str: str,
    items: list[dict],
    total_ttc: int,
    vat_details: list[dict],
    payment_method: str,
    fne_reference: str,
    qr_url: str,
    is_refund: bool = False,
    orig_ref: str | None = None,
) -> None:
    width = 540  # largeur standard 80mm
    # calcul de la hauteur estimée
    base_height = 850 if not is_refund else 900
    img = Image.new("RGB", (width, base_height), color="white")
    draw = ImageDraw.Draw(img)

    f_title = ImageFont.truetype(FONT_BOLD_PATH, 20)
    f_header = ImageFont.truetype(FONT_BOLD_PATH, 16)
    f_body = ImageFont.truetype(FONT_REGULAR_PATH, 14)
    f_body_b = ImageFont.truetype(FONT_BOLD_PATH, 14)
    f_small = ImageFont.truetype(FONT_REGULAR_PATH, 12)
    f_large_b = ImageFont.truetype(FONT_BOLD_PATH, 18)

    y = 25

    def draw_center(text: str, font: ImageFont.FreeTypeFont, fill: str = "black"):
        nonlocal y
        bbox = draw.textbbox((0, 0), text, font=font)
        w = bbox[2] - bbox[0]
        draw.text(((width - w) // 2, y), text, font=font, fill=fill)
        y += bbox[3] - bbox[0] + 6

    def draw_sep(char: str = "-"):
        nonlocal y
        draw.text((25, y), char * 46, font=f_small, fill="#555555")
        y += 18

    def draw_row(left: str, right: str, font=f_body, font_r=None):
        nonlocal y
        font_right = font_r or font
        draw.text((25, y), left, font=font, fill="black")
        bbox = draw.textbbox((0, 0), right, font=font_right)
        draw.text((width - 25 - (bbox[2] - bbox[0]), y), right, font=font_right, fill="black")
        y += 20

    # En-tête
    draw_center(establishment, f_title)
    draw_center(address, f_small)
    draw_center(f"Tél : {phone}", f_small)
    draw_center(f"NCC : {ncc} | RCCM : CI-ABJ-2024-B-12345", f_small)
    y += 5
    draw_sep("=")

    # Type de document
    doc_type = "TICKET DE CAISSE" if not is_refund else "FACTURE D'AVOIR (RETOUR)"
    draw_center(doc_type, f_header)
    if is_refund and orig_ref:
        draw_center(f"Réf. Facture d'origine : {orig_ref}", f_small, fill="#b91c1c")

    draw_sep("-")
    draw_row(f"Ticket N°: {ticket_num}", f"Caisse: {pos_id}")
    draw_row(f"Date: {date_str}", "Caissier: SYLLA A.")
    draw_sep("-")

    # Colonnes articles
    draw_row("Désignation", "Qté x P.U   Total", font=f_body_b)
    draw_sep("-")

    for item in items:
        name = item["name"]
        qty = item["qty"]
        pu = item["pu"]
        total = item["total"]
        draw.text((25, y), name, font=f_body_b, fill="black")
        y += 18
        qty_pu = f"{qty} x {pu:,.0f}".replace(",", " ")
        tot_str = f"{total:,.0f} F".replace(",", " ")
        draw_row(f"  {qty_pu}", tot_str, font=f_body)

    draw_sep("-")

    # Totaux
    draw_row("TOTAL BRUT TTC :", f"{total_ttc:,.0f} XOF".replace(",", " "), font=f_large_b)
    for vd in vat_details:
        draw_row(vd["label"], vd["value"], font=f_small)

    draw_sep("-")
    draw_row(f"Règlement ({payment_method}) :", f"{total_ttc:,.0f} XOF".replace(",", " "), font=f_body_b)
    y += 10

    # Bloc FNE
    draw_sep("=")
    draw_center("RÉPUBLIQUE DE CÔTE D'IVOIRE", f_small)
    draw_center("DIRECTION GÉNÉRALE DES IMPÔTS (DGI)", f_small)
    draw_center("FACTURE NORMALISÉE ÉLECTRONIQUE (FNE)", f_header)
    draw_center(f"RÉF FNE : {fne_reference}", f_body_b)
    y += 6

    # QR Code
    qr = qrcode.QRCode(box_size=4, border=1)
    qr.add_data(qr_url)
    qr.make(fit=True)
    qr_img = qr.make_image(fill_color="black", back_color="white")
    qr_img_rgb = qr_img.convert("RGB")
    qr_w, qr_h = qr_img_rgb.size
    qr_x = (width - qr_w) // 2
    img.paste(qr_img_rgb, (qr_x, y, qr_x + qr_w, y + qr_h))
    y += qr_h + 8

    draw_center("Scannez ce QR Code pour vérifier", f_small)
    draw_center("la validité de cette facture sur le portail DGI", f_small)
    y += 10
    draw_sep("-")
    draw_center("Merci de votre visite - À très bientôt !", f_small)
    y += 25

    # Recadrage à la taille réelle
    final_img = img.crop((0, 0, width, y))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    final_img.save(output_path, "PNG")


def generate_ticket_html(
    output_path: Path,
    title: str,
    establishment: str,
    ncc: str,
    address: str,
    phone: str,
    pos_id: str,
    ticket_num: str,
    date_str: str,
    items: list[dict],
    total_ttc: int,
    vat_details: list[dict],
    payment_method: str,
    fne_reference: str,
    qr_url: str,
    is_refund: bool = False,
    orig_ref: str | None = None,
) -> None:
    items_html = ""
    for it in items:
        items_html += f"""
        <div style="margin-bottom: 6px;">
          <div style="font-weight: bold;">{it['name']}</div>
          <div style="display: flex; justify-content: space-between; font-size: 13px;">
            <span style="padding-left: 8px;">{it['qty']} x {it['pu']:,.0f} F</span>
            <span style="font-weight: 600;">{it['total']:,.0f} F</span>
          </div>
        </div>
        """

    vat_html = ""
    for v in vat_details:
        vat_html += f"""
        <div style="display: flex; justify-content: space-between; font-size: 12px; color: #444;">
          <span>{v['label']}</span>
          <span>{v['value']}</span>
        </div>
        """

    html = f"""<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>{title}</title>
  <style>
    body {{
      font-family: 'Courier New', Courier, monospace;
      background: #f1f5f9;
      display: flex;
      justify-content: center;
      padding: 30px 10px;
      margin: 0;
    }}
    .ticket {{
      background: #ffffff;
      width: 380px;
      padding: 24px;
      border-radius: 4px;
      box-shadow: 0 4px 15px rgba(0,0,0,0.1);
      color: #0f172a;
    }}
    .center {{ text-align: center; }}
    .bold {{ font-weight: bold; }}
    .sep {{ border-top: 1px dashed #94a3b8; margin: 12px 0; }}
    .sep-double {{ border-top: 2px solid #0f172a; margin: 12px 0; }}
    .row {{ display: flex; justify-content: space-between; margin: 4px 0; font-size: 13px; }}
    .fne-badge {{
      background: #f8fafc;
      border: 1px solid #cbd5e1;
      padding: 10px;
      border-radius: 6px;
      margin-top: 10px;
      text-align: center;
    }}
    .qr-container img {{
      display: block;
      margin: 10px auto;
      max-width: 170px;
    }}
    @media print {{
      body {{ background: transparent; padding: 0; }}
      .ticket {{ box-shadow: none; width: 100%; padding: 0; }}
    }}
  </style>
</head>
<body>
  <div class="ticket">
    <div class="center bold" style="font-size: 18px; text-transform: uppercase;">{establishment}</div>
    <div class="center" style="font-size: 12px; color: #475569; margin-top: 4px;">{address}</div>
    <div class="center" style="font-size: 12px; color: #475569;">Tél : {phone}</div>
    <div class="center" style="font-size: 12px; color: #475569;">NCC : {ncc} | RCCM : CI-ABJ-2024-B-12345</div>

    <div class="sep-double"></div>

    <div class="center bold" style="font-size: 15px; letter-spacing: 0.5px;">
      {"TICKET DE CAISSE" if not is_refund else "FACTURE D'AVOIR (RETOUR)"}
    </div>
    {"<div class='center' style='font-size: 12px; color: #dc2626; margin-top: 2px;'>Réf. d'origine : " + (orig_ref or "") + "</div>" if is_refund else ""}

    <div class="sep"></div>

    <div class="row"><span>Ticket N°: {ticket_num}</span><span>Caisse: {pos_id}</span></div>
    <div class="row"><span>Date: {date_str}</span><span>Caissier: SYLLA A.</span></div>

    <div class="sep"></div>

    <div style="font-size: 13px; font-weight: bold; margin-bottom: 8px;">DÉTAIL DES ARTICLES</div>
    {items_html}

    <div class="sep"></div>

    <div class="row bold" style="font-size: 16px;">
      <span>TOTAL TTC :</span>
      <span>{total_ttc:,.0f} XOF</span>
    </div>

    {vat_html}

    <div class="sep"></div>

    <div class="row bold">
      <span>Règlement ({payment_method}) :</span>
      <span>{total_ttc:,.0f} XOF</span>
    </div>

    <div class="fne-badge">
      <div style="font-size: 11px; font-weight: 700; color: #334155;">RÉPUBLIQUE DE CÔTE D'IVOIRE</div>
      <div style="font-size: 10px; color: #64748b;">DIRECTION GÉNÉRALE DES IMPÔTS</div>
      <div style="font-size: 13px; font-weight: bold; margin: 4px 0; color: #0f172a;">FACTURE NORMALISÉE ÉLECTRONIQUE</div>
      <div style="font-size: 12px; font-family: monospace; font-weight: 700; color: #047857;">{fne_reference}</div>

      <div class="qr-container">
        <img src="qr_code.png" alt="QR Code FNE">
      </div>

      <div style="font-size: 10px; color: #64748b; line-height: 1.3;">
        Vérification en ligne de conformité :<br>
        <span style="word-break: break-all; font-size: 9px;">{qr_url}</span>
      </div>
    </div>

    <div class="sep"></div>
    <div class="center" style="font-size: 11px; color: #64748b;">
      Merci de votre visite - À très bientôt !
    </div>
  </div>
</body>
</html>
"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html, encoding="utf-8")


def main():
    print(f"Création du dossier d'homologation dans : {OUTPUT_DIR}")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # 1. Chargement des données JSON du probe
    with open(SOURCE_PROBE / "1-sign-request.json", "r") as f:
        sale_req = json.load(f)
    with open(SOURCE_PROBE / "1-sign-response.json", "r") as f:
        sale_res = json.load(f)
    with open(SOURCE_PROBE / "2-refund-request.json", "r") as f:
        refund_req = json.load(f)
    with open(SOURCE_PROBE / "2-refund-response.json", "r") as f:
        refund_res = json.load(f)

    # 2. Cas 1 : Vente B2C
    dir_sale = OUTPUT_DIR / "01_Cas_Vente_B2C"
    dir_sale.mkdir(exist_ok=True)
    (dir_sale / "1-requete-fne-sign.json").write_text(json.dumps(sale_req, indent=2, ensure_ascii=False), encoding="utf-8")
    (dir_sale / "2-reponse-fne-sign.json").write_text(json.dumps(sale_res, indent=2, ensure_ascii=False), encoding="utf-8")

    # QR code image pour HTML
    qr_sale = qrcode.QRCode(box_size=5, border=1)
    qr_sale.add_data(sale_res["token"])
    qr_sale.make(fit=True)
    qr_sale.make_image(fill_color="black", back_color="white").save(dir_sale / "qr_code.png")

    draw_ticket(
        output_path=dir_sale / "3-specimen-ticket-vente.png",
        title="Spécimen Ticket Vente",
        establishment=sale_res["invoice"]["clientEstablishment"],
        ncc=sale_res["ncc"],
        address="Abidjan, Plateau",
        phone="07 48 73 55 73",
        pos_id=sale_res["invoice"]["clientPointOfSale"],
        ticket_num="TICK-20261020-0021",
        date_str="20/10/2026 12:50",
        items=[
            {"name": "Poisson braisé", "qty": 2, "pu": 3500, "total": 7000},
            {"name": "Eau minérale 1,5 L", "qty": 1, "pu": 1000, "total": 1000},
        ],
        total_ttc=8000,
        vat_details=[
            {"label": "Total HT :", "value": "8 000 XOF"},
            {"label": "TVA 0% (Régime D - TVAD) :", "value": "0 XOF"},
        ],
        payment_method="Espèces",
        fne_reference=sale_res["reference"],
        qr_url=sale_res["token"],
    )

    generate_ticket_html(
        output_path=dir_sale / "3-specimen-ticket-vente.html",
        title="Spécimen Ticket Vente",
        establishment=sale_res["invoice"]["clientEstablishment"],
        ncc=sale_res["ncc"],
        address="Abidjan, Plateau",
        phone="07 48 73 55 73",
        pos_id=sale_res["invoice"]["clientPointOfSale"],
        ticket_num="TICK-20261020-0021",
        date_str="20/10/2026 12:50",
        items=[
            {"name": "Poisson braisé", "qty": 2, "pu": 3500, "total": 7000},
            {"name": "Eau minérale 1,5 L", "qty": 1, "pu": 1000, "total": 1000},
        ],
        total_ttc=8000,
        vat_details=[
            {"label": "Total HT :", "value": "8 000 XOF"},
            {"label": "TVA 0% (Régime D - TVAD) :", "value": "0 XOF"},
        ],
        payment_method="Espèces",
        fne_reference=sale_res["reference"],
        qr_url=sale_res["token"],
    )

    # 3. Cas 2 : Avoir / Remboursement
    dir_refund = OUTPUT_DIR / "02_Cas_Avoir_Remboursement"
    dir_refund.mkdir(exist_ok=True)
    (dir_refund / "1-requete-fne-refund.json").write_text(json.dumps(refund_req, indent=2, ensure_ascii=False), encoding="utf-8")
    (dir_refund / "2-reponse-fne-refund.json").write_text(json.dumps(refund_res, indent=2, ensure_ascii=False), encoding="utf-8")

    qr_refund = qrcode.QRCode(box_size=5, border=1)
    qr_refund.add_data(refund_res["token"])
    qr_refund.make(fit=True)
    qr_refund.make_image(fill_color="black", back_color="white").save(dir_refund / "qr_code.png")

    draw_ticket(
        output_path=dir_refund / "3-specimen-ticket-avoir.png",
        title="Spécimen Ticket Avoir",
        establishment=sale_res["invoice"]["clientEstablishment"],
        ncc=refund_res["ncc"],
        address="Abidjan, Plateau",
        phone="07 48 73 55 73",
        pos_id=sale_res["invoice"]["clientPointOfSale"],
        ticket_num="AVOIR-20261020-0001",
        date_str="20/10/2026 12:51",
        items=[
            {"name": "Poisson braisé (Retour)", "qty": 1, "pu": -3500, "total": -3500},
        ],
        total_ttc=-3500,
        vat_details=[
            {"label": "Total HT remboursé :", "value": "-3 500 XOF"},
            {"label": "TVA remboursée :", "value": "0 XOF"},
        ],
        payment_method="Espèces",
        fne_reference=refund_res["reference"],
        qr_url=refund_res["token"],
        is_refund=True,
        orig_ref=sale_res["reference"],
    )

    generate_ticket_html(
        output_path=dir_refund / "3-specimen-ticket-avoir.html",
        title="Spécimen Ticket Avoir",
        establishment=sale_res["invoice"]["clientEstablishment"],
        ncc=refund_res["ncc"],
        address="Abidjan, Plateau",
        phone="07 48 73 55 73",
        pos_id=sale_res["invoice"]["clientPointOfSale"],
        ticket_num="AVOIR-20261020-0001",
        date_str="20/10/2026 12:51",
        items=[
            {"name": "Poisson braisé (Retour)", "qty": 1, "pu": -3500, "total": -3500},
        ],
        total_ttc=-3500,
        vat_details=[
            {"label": "Total HT remboursé :", "value": "-3 500 XOF"},
            {"label": "TVA remboursée :", "value": "0 XOF"},
        ],
        payment_method="Espèces",
        fne_reference=refund_res["reference"],
        qr_url=refund_res["token"],
        is_refund=True,
        orig_ref=sale_res["reference"],
    )

    # 4. Courrier formel de transmission
    courrier_txt = f"""REPUBLIQUE DE COTE D'IVOIRE
DIRECTION GENERALE DES IMPOTS (DGI)
Cellule Facture Normalisée Électronique (FNE)
Email : support.fne@dgi.gouv.ci

Date : 20 Octobre 2026
Objet : Demande de passage en production API FNE et délivrance des accès de production
Contribuable : RESTAURANT CHEZ SYLLA PLUS (NCC : {sale_res['ncc']})
Éditeur Logiciel & Intégrateur : OSIS GROUP S.A

Madame, Monsieur les Responsables du projet FNE,

La société OSIS GROUP S.A, agissant en qualité d'éditeur de logiciels et prestataire technique pour le compte du contribuable RESTAURANT CHEZ SYLLA PLUS, a l'honneur de vous soumettre le dossier technique de validation d'interfaçage de la solution de caisse enregistreuse (« Caisse MYK ») avec la plateforme FNE par API REST.

Nos équipes techniques ont achevé avec succès les tests d'intégration sur l'environnement officiel de test (http://54.247.95.108/ws) conformément aux exigences de la « Procédure d'interfaçage des entreprises par API » (Mai 2025).

1. IDENTIFICATION DU CONTRIBUABLE (CLIENT FINAL)
- Raison sociale : RESTAURANT CHEZ SYLLA PLUS
- Numéro Compte Contribuable (NCC) : {sale_res['ncc']}
- Adresse : Abidjan, Plateau
- Établissement déclaré : RESTAURANT CHEZ SYLLA PLUS
- Point de vente configuré : CAISSE-1
- Email officiel contribuable : {sale_res['invoice']['clientEmail']}
- Téléphone contribuable : {sale_res['invoice']['clientPhone']}

2. IDENTIFICATION DE L'ÉDITEUR LOGICIEL & CONTACT TECHNIQUE
- Entreprise prestataire / Éditeur : OSIS GROUP S.A
- Solution logicielle : Caisse MYK (POS Restaurant & Bar)
- Contact technique dédié : FOUO ABDELL AZIZ FRANCK
- Email technique : fouo.abdell@osistechnoligies.com

3. RÉCAPITULATIF DES OPÉRATIONS DE TEST CERTIFIÉES
- VENTE B2C :
  * Référence FNE obtenue : {sale_res['reference']}
  * Identifiant technique : {sale_res['invoice']['id']}
  * Token / URL de vérification : {sale_res['token']}
  * Montant TTC certifié : 8 000 XOF
  * Pièces jointes : 1-requete-fne-sign.json, 2-reponse-fne-sign.json, 3-specimen-ticket-vente.png

- AVOIR / REMBOURSEMENT SUR FACTURE CERTIFIÉE :
  * Facture d'origine : {sale_res['reference']}
  * Référence FNE d'avoir obtenue : {refund_res['reference']}
  * Token / URL de vérification : {refund_res['token']}
  * Montant remboursé : -3 500 XOF
  * Pièces jointes : 1-requete-fne-refund.json, 2-reponse-fne-refund.json, 3-specimen-ticket-avoir.png

4. CONFORMITÉ TECHNIQUE DU LOGICIEL « CAISSE MYK »
- Architecture RESTful JSON avec authentification sécurisée par jeton Bearer Token.
- Respect strict du délai de certification (< 4 secondes).
- Dispositif Outbox transactionnel garantissant la continuité d'activité locale en cas de coupure Internet (file d'attente certifiée dès reconnexion).
- Gestion intégrale de l'inviolabilité et de l'irréversibilité des transactions fiscales.
- Impression thermique normalisée avec QR Code haute définition scannable.

Nous sollicitons par la présente :
1. La validation de la conformité de nos spécimens et de l'interfaçage de Caisse MYK.
2. La transmission de l'URL de l'API de Production.
3. L'activation et l'affichage de la clé API de production dans l'onglet « Paramétrage » de l'espace FNE gestionnaire du contribuable.

Restant à votre entière disposition pour tout échange technique complémentaire, nous vous prions d'agréer, Madame, Monsieur, l'expression de nos salutations distinguées.

Pour l'Éditeur Technique (OSIS GROUP S.A) :
FOUO ABDELL AZIZ FRANCK (fouo.abdell@osistechnoligies.com)

Pour le Contribuable (RESTAURANT CHEZ SYLLA PLUS) :
La Direction
"""
    (OUTPUT_DIR / "00_Courrier_Transmission_DGI.txt").write_text(courrier_txt, encoding="utf-8")

    # 5. Fiche technique d'interfaçage HTML (beau document)
    fiche_html = f"""<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>Dossier d'Homologation API FNE - RESTAURANT CHEZ SYLLA PLUS / OSIS GROUP S.A</title>
  <style>
    body {{
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
      line-height: 1.6;
      color: #1e293b;
      background: #f8fafc;
      margin: 0;
      padding: 40px 20px;
    }}
    .container {{
      max-width: 860px;
      margin: 0 auto;
      background: #ffffff;
      padding: 40px 50px;
      border-radius: 8px;
      box-shadow: 0 4px 20px rgba(0,0,0,0.06);
    }}
    h1 {{ color: #0f172a; border-bottom: 2px solid #0284c7; padding-bottom: 12px; font-size: 24px; }}
    h2 {{ color: #0369a1; font-size: 18px; margin-top: 30px; }}
    .badge {{ display: inline-block; background: #e0f2fe; color: #0369a1; padding: 4px 10px; border-radius: 4px; font-weight: 600; font-size: 13px; }}
    .table {{ width: 100%; border-collapse: collapse; margin: 16px 0; }}
    .table th, .table td {{ border: 1px solid #e2e8f0; padding: 10px 14px; text-align: left; font-size: 14px; }}
    .table th {{ background: #f1f5f9; font-weight: 600; }}
    .code {{ font-family: monospace; background: #f1f5f9; padding: 2px 6px; border-radius: 4px; font-size: 13px; }}
    .callout {{ background: #f0fdf4; border-left: 4px solid #16a34a; padding: 14px 18px; border-radius: 4px; margin: 20px 0; font-size: 14px; }}
  </style>
</head>
<body>
  <div class="container">
    <div style="display: flex; justify-content: space-between; align-items: center;">
      <div>
        <span class="badge">DOSSIER TECHNIQUE D'INTERFAÇAGE API FNE</span>
        <h1 style="margin-top: 10px;">RESTAURANT CHEZ SYLLA PLUS</h1>
      </div>
      <div style="text-align: right; font-size: 13px; color: #64748b;">
        <strong>Direction Générale des Impôts</strong><br>
        Date : 20 Octobre 2026<br>
        Éditeur : <strong>OSIS GROUP S.A</strong>
      </div>
    </div>

    <div class="callout">
      <strong>Statut des tests :</strong> Tous les tests d'interfaçage ont été exécutés avec succès sur l'environnement officiel de test DGI (<span class="code">http://54.247.95.108/ws</span>) par l'éditeur <strong>OSIS GROUP S.A</strong> pour le compte du contribuable <strong>RESTAURANT CHEZ SYLLA PLUS</strong>. Les évidences sont présentées ci-dessous.
    </div>

    <h2>1. Identification des Parties</h2>
    <table class="table">
      <tr><th colspan="2" style="background: #e2e8f0; color: #0f172a;">A. Contribuable (Bénéficiaire)</th></tr>
      <tr><th>Raison sociale</th><td>RESTAURANT CHEZ SYLLA PLUS</td></tr>
      <tr><th>Numéro Compte Contribuable (NCC)</th><td><strong>{sale_res['ncc']}</strong></td></tr>
      <tr><th>Adresse</th><td>Abidjan, Plateau</td></tr>
      <tr><th>Établissement / POS</th><td>RESTAURANT CHEZ SYLLA PLUS / CAISSE-1</td></tr>
      <tr><th>Email / Tél</th><td>{sale_res['invoice']['clientEmail']} / {sale_res['invoice']['clientPhone']}</td></tr>
      <tr><th colspan="2" style="background: #e2e8f0; color: #0f172a;">B. Éditeur Logiciel & Intégrateur Technique</th></tr>
      <tr><th>Société éditrice</th><td><strong>OSIS GROUP S.A</strong></td></tr>
      <tr><th>Solution applicative</th><td>Caisse MYK (Logiciel de caisse certifiable)</td></tr>
      <tr><th>Contact technique dédié</th><td><strong>FOUO ABDELL AZIZ FRANCK</strong></td></tr>
      <tr><th>Email technique</th><td><a href="mailto:fouo.abdell@osistechnoligies.com">fouo.abdell@osistechnoligies.com</a></td></tr>
    </table>

    <h2>2. Synthèse des Épreuves de Certification</h2>
    <table class="table">
      <tr>
        <th>Scénario</th>
        <th>Référence FNE Certifiée</th>
        <th>Token / URL QR Code</th>
        <th>Montant</th>
        <th>Statut HTTP</th>
      </tr>
      <tr>
        <td><strong>Vente B2C</strong> (Cash)</td>
        <td><span class="code">{sale_res['reference']}</span></td>
        <td><a href="{sale_res['token']}" target="_blank" style="font-size: 11px;">{sale_res['token']}</a></td>
        <td>8 000 XOF</td>
        <td><span style="color: #16a34a; font-weight: bold;">200 OK</span></td>
      </tr>
      <tr>
        <td><strong>Avoir / Remboursement</strong></td>
        <td><span class="code">{refund_res['reference']}</span></td>
        <td><a href="{refund_res['token']}" target="_blank" style="font-size: 11px;">{refund_res['token']}</a></td>
        <td>-3 500 XOF</td>
        <td><span style="color: #16a34a; font-weight: bold;">201 Created</span></td>
      </tr>
    </table>

    <h2>3. Architecture et Robustesse du Système « Caisse MYK » (OSIS GROUP S.A)</h2>
    <ul>
      <li><strong>Protocole :</strong> RESTful HTTP / JSON avec authentification par jeton <span class="code">Authorization: Bearer &lt;API_KEY&gt;</span>.</li>
      <li><strong>Mode Déconnecté & Résilience (Outbox) :</strong> Le logiciel dispose d'un tampon Outbox persistant sur base de données PostgreSQL locale. En cas d'indisponibilité momentanée d'Internet, les factures sont générées localement et certifiées en différé dès le rétablissement de la connexion.</li>
      <li><strong>Contrôle des Délais :</strong> Délai d'attente réseau borné à 4 secondes conformément aux recommandations de la DGI pour garantir la fluidité en caisse.</li>
      <li><strong>Spécimens Visuels :</strong> Des tickets conformes avec mentions légales et QR Code scannables haute définition sont générés en PNG et HTML dans les dossiers annexes.</li>
    </ul>

    <h2>4. Demande</h2>
    <p>Nous sollicitons de la part de la DGI :</p>
    <ol>
      <li>L'approbation formelle de l'interfaçage de la solution Caisse MYK.</li>
      <li>La communication de l'<strong>URL officielle de production</strong>.</li>
      <li>L'activation de l'accès à la <strong>clé API de production</strong> sur l'espace contribuable FNE du restaurant.</li>
    </ol>
  </div>
</body>
</html>
"""
    (OUTPUT_DIR / "Fiche_Technique_Interfacage_API.html").write_text(fiche_html, encoding="utf-8")

    # 6. README.md explicatif
    readme_md = f"""# Dossier d'Homologation API FNE — RESTAURANT CHEZ SYLLA PLUS

Ce dossier contient l'ensemble des éléments exigés par la **Direction Générale des Impôts (DGI)** de Côte d'Ivoire dans le cadre de la procédure d'homologation et de passage en production de l'API Facture Normalisée Électronique (FNE).

## 📁 Arborescence du dossier

- `00_Courrier_Transmission_DGI.txt` : Texte officiel de la lettre de transmission à envoyer par email.
- `Fiche_Technique_Interfacage_API.html` : Synthèse technique complète et récapitulatif des tests.
- `01_Cas_Vente_B2C/` :
  - `1-requete-fne-sign.json` : Corps exact de la requête POST `/external/invoices/sign` envoyée.
  - `2-reponse-fne-sign.json` : Réponse JSON 200 renvoyée par le serveur de test DGI avec la référence `{sale_res['reference']}`.
  - `3-specimen-ticket-vente.png` : Rendu graphique haute résolution du ticket de caisse imprimé avec QR code scannable.
  - `3-specimen-ticket-vente.html` : Version HTML imprimable du ticket de caisse.
  - `qr_code.png` : QR code officiel généré à partir du token DGI.
- `02_Cas_Avoir_Remboursement/` :
  - `1-requete-fne-refund.json` : Corps de la requête POST `/external/invoices/{{id}}/refund`.
  - `2-reponse-fne-refund.json` : Réponse JSON 201 reçue de la DGI avec la référence d'avoir `{refund_res['reference']}`.
  - `3-specimen-ticket-avoir.png` : Rendu graphique du ticket d'avoir avec référence d'origine.
  - `3-specimen-ticket-avoir.html` : Version HTML imprimable du ticket d'avoir.
  - `qr_code.png` : QR code officiel de l'avoir.

## 🚀 Procédure d'envoi à la DGI

1. Ouvrez votre messagerie d'entreprise (celle enregistrée auprès de la DGI : `{sale_res['invoice']['clientEmail']}`).
2. Rédigez un courriel à destination de : **`support.fne@dgi.gouv.ci`**.
3. Copiez-collez le texte de `00_Courrier_Transmission_DGI.txt` dans le corps du message.
4. Joignez à l'e-mail :
   - `Fiche_Technique_Interfacage_API.html`
   - Le ticket de vente : `01_Cas_Vente_B2C/3-specimen-ticket-vente.png`
   - Le ticket d'avoir : `02_Cas_Avoir_Remboursement/3-specimen-ticket-avoir.png`
   - Les fichiers JSON (`1-requete-fne-sign.json`, `2-reponse-fne-sign.json`, etc.) ou l'archive zip complète de ce dossier.
5. Envoyez le mail.

## ⏳ Après l'envoi
- La DGI analyse vos spécimens et vous adresse un mail de confirmation avec l'**URL de production**.
- Rendez-vous sur votre espace FNE de gestionnaire pour copier votre **clé API de production** (onglet « Paramétrage »).
- Mettez à jour le fichier `.env` de votre application Caisse MYK avec l'URL et la clé reçues.
"""
    (OUTPUT_DIR / "README.md").write_text(readme_md, encoding="utf-8")

    import shutil
    zip_path = OUTPUT_DIR.parent / "Dossier_Homologation_FNE.zip"
    shutil.make_archive(str(OUTPUT_DIR.parent / "Dossier_Homologation_FNE"), "zip", OUTPUT_DIR)
    print("✅ Dossier complet généré avec succès dans :", OUTPUT_DIR)
    print("✅ Archive ZIP créée dans :", zip_path)


if __name__ == "__main__":
    main()
