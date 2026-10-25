import argparse
import sys

from sqlalchemy.orm import Session

from caisse.core.security import hash_pin
from caisse.services.auth_service import AuthService


def cmd_create_user(db: Session, args: argparse.Namespace) -> None:
    auth_service = AuthService(db)
    if args.noinput or (args.name and args.role and args.pin):
        name = args.name or sys.stdin.readline().strip()
        role = args.role or "CAISSIER"
        pin = args.pin or "123456"
    else:
        name = input("Nom complet : ").strip()
        role = input("Rôle [CAISSIER/RESPONSABLE/ADMIN/ECONOME] : ").strip().upper()
        pin = input("PIN (6 chiffres) : ").strip()

    user = auth_service.create_user(full_name=name, pin=pin, role=role)
    print(f" Utilisateur '{user.full_name}' ({user.role}) créé avec succès. ID: {user.id}")


def cmd_reset_pin(db: Session, args: argparse.Namespace) -> None:
    auth_service = AuthService(db)
    target_user = auth_service.user_repo.get_by_name(args.name)
    if not target_user:
        print(f" Utilisateur '{args.name}' introuvable.")
        sys.exit(1)
    new_pin = args.new_pin or input(f"Nouveau PIN pour {target_user.full_name} : ").strip()
    target_user.pin_hash = hash_pin(new_pin)
    target_user.failed_attempts = 0
    target_user.locked_until = None
    db.commit()
    print(f" PIN de '{target_user.full_name}' réinitialisé avec succès.")
