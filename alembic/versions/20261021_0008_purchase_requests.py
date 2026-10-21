"""Approvisionnement : demandes d'achat et rôle ACHETEUR

L'acheteur saisit les quantités à acheter, sans voir les prix ; le montant à lui remettre est
calculé au dernier prix d'achat. Un responsable valide, décaisse, puis réceptionne : la
réception crée les entrées de stock (`purchase_request_lines.stock_movement_id`).

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-21 16:07:28
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0008'
down_revision: str | None = '0007'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_ROLES_OLD = "('CAISSIER', 'RESPONSABLE', 'ADMIN')"
_ROLES_NEW = "('ACHETEUR', 'CAISSIER', 'RESPONSABLE', 'ADMIN')"


def upgrade() -> None:
    op.drop_constraint(op.f('ck_users_user_role'), 'users', type_='check')
    op.create_check_constraint(op.f('ck_users_user_role'), 'users', f"role IN {_ROLES_NEW}")

    op.create_table('purchase_requests',
    sa.Column('number', sa.String(length=16), nullable=False),
    sa.Column('status', sa.Enum('SUBMITTED', 'APPROVED', 'DISBURSED', 'RECEIVED', 'REJECTED', 'CANCELLED', name='purchase_status', native_enum=False, create_constraint=True, length=32), nullable=False),
    sa.Column('requested_by_user_id', sa.Uuid(), nullable=False),
    sa.Column('note', sa.String(length=255), nullable=True),
    sa.Column('estimated_total_xof', sa.Integer(), nullable=False),
    sa.Column('approved_total_xof', sa.Integer(), nullable=True),
    sa.Column('approved_by_user_id', sa.Uuid(), nullable=True),
    sa.Column('approved_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('disbursed_xof', sa.Integer(), nullable=True),
    sa.Column('disbursed_by_user_id', sa.Uuid(), nullable=True),
    sa.Column('disbursed_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('received_total_xof', sa.Integer(), nullable=True),
    sa.Column('received_by_user_id', sa.Uuid(), nullable=True),
    sa.Column('received_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('supplier', sa.String(length=120), nullable=True),
    sa.Column('closed_reason', sa.String(length=255), nullable=True),
    sa.Column('closed_by_user_id', sa.Uuid(), nullable=True),
    sa.Column('closed_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['approved_by_user_id'], ['users.id'], name=op.f('fk_purchase_requests_approved_by_user_id_users'), ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['closed_by_user_id'], ['users.id'], name=op.f('fk_purchase_requests_closed_by_user_id_users'), ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['disbursed_by_user_id'], ['users.id'], name=op.f('fk_purchase_requests_disbursed_by_user_id_users'), ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['received_by_user_id'], ['users.id'], name=op.f('fk_purchase_requests_received_by_user_id_users'), ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['requested_by_user_id'], ['users.id'], name=op.f('fk_purchase_requests_requested_by_user_id_users'), ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_purchase_requests')),
    sa.UniqueConstraint('number', name=op.f('uq_purchase_requests_number'))
    )
    op.create_index(op.f('ix_purchase_requests_requested_by_user_id'), 'purchase_requests', ['requested_by_user_id'], unique=False)
    op.create_index(op.f('ix_purchase_requests_status'), 'purchase_requests', ['status'], unique=False)
    op.create_table('purchase_request_lines',
    sa.Column('request_id', sa.Uuid(), nullable=False),
    sa.Column('article_id', sa.Uuid(), nullable=False),
    sa.Column('requested_quantity', sa.Numeric(precision=12, scale=3), nullable=False),
    sa.Column('approved_quantity', sa.Numeric(precision=12, scale=3), nullable=True),
    sa.Column('unit_price_xof', sa.Numeric(precision=12, scale=2), nullable=False),
    sa.Column('received_quantity', sa.Numeric(precision=12, scale=3), nullable=True),
    sa.Column('received_cost_xof', sa.Integer(), nullable=True),
    sa.Column('stock_movement_id', sa.Uuid(), nullable=True),
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.CheckConstraint('requested_quantity > 0', name=op.f('ck_purchase_request_lines_requested_quantity_positive')),
    sa.ForeignKeyConstraint(['article_id'], ['stock_articles.id'], name=op.f('fk_purchase_request_lines_article_id_stock_articles'), ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['request_id'], ['purchase_requests.id'], name=op.f('fk_purchase_request_lines_request_id_purchase_requests'), ondelete='RESTRICT'),
    sa.ForeignKeyConstraint(['stock_movement_id'], ['stock_movements.id'], name=op.f('fk_purchase_request_lines_stock_movement_id_stock_movements'), ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_purchase_request_lines')),
    sa.UniqueConstraint('request_id', 'article_id', name='uq_purchase_request_lines_article')
    )
    op.create_index(op.f('ix_purchase_request_lines_article_id'), 'purchase_request_lines', ['article_id'], unique=False)
    op.create_index(op.f('ix_purchase_request_lines_request_id'), 'purchase_request_lines', ['request_id'], unique=False)


def downgrade() -> None:
    buyers = op.get_bind().execute(
        sa.text("SELECT count(*) FROM users WHERE role = 'ACHETEUR'")
    ).scalar_one()
    if buyers:
        raise RuntimeError(
            f"{buyers} utilisateur(s) ACHETEUR : changer leur rôle ou les supprimer avant le "
            "retour arrière (leurs demandes d'achat seraient perdues)"
        )
    op.drop_index(op.f('ix_purchase_request_lines_request_id'), table_name='purchase_request_lines')
    op.drop_index(op.f('ix_purchase_request_lines_article_id'), table_name='purchase_request_lines')
    op.drop_table('purchase_request_lines')
    op.drop_index(op.f('ix_purchase_requests_status'), table_name='purchase_requests')
    op.drop_index(op.f('ix_purchase_requests_requested_by_user_id'), table_name='purchase_requests')
    op.drop_table('purchase_requests')
    op.drop_constraint(op.f('ck_users_user_role'), 'users', type_='check')
    op.create_check_constraint(op.f('ck_users_user_role'), 'users', f"role IN {_ROLES_OLD}")
