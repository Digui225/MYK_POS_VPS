"""Impression tirée par l'agent : terminaux à jeton, prise des travaux, tiroir et test en file

L'API, sur le VPS, ne peut plus appeler l'agent du restaurant : c'est l'agent qui vient
chercher les travaux (`claimed_at`, `terminal_id`). L'ouverture manuelle du tiroir et le
ticket de test deviennent des travaux comme les autres (`DRAWER`, `TEST`).

Revision ID: 0007
Revises: 0006
Create Date: 2026-10-20 16:00:00
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = '0007'
down_revision: str | None = '0006'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_TYPES_OLD = "('RECEIPT', 'X_REPORT', 'Z_REPORT', 'FNE', 'ORDER_TICKET')"
_TYPES_NEW = "('RECEIPT', 'X_REPORT', 'Z_REPORT', 'FNE', 'ORDER_TICKET', 'DRAWER', 'TEST')"


def upgrade() -> None:
    op.create_table('print_terminals',
    sa.Column('name', sa.String(length=60), nullable=False),
    sa.Column('token_hash', sa.String(length=64), nullable=False),
    sa.Column('revoked_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('last_seen_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('printer_status', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('created_by', sa.Uuid(), nullable=True),
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['created_by'], ['users.id'], name=op.f('fk_print_terminals_created_by_users'), ondelete='RESTRICT'),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_print_terminals')),
    sa.UniqueConstraint('name', name=op.f('uq_print_terminals_name')),
    sa.UniqueConstraint('token_hash', name=op.f('uq_print_terminals_token_hash'))
    )
    op.add_column('print_jobs', sa.Column('claimed_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('print_jobs', sa.Column('terminal_id', sa.Uuid(), nullable=True))
    op.create_foreign_key(
        op.f('fk_print_jobs_terminal_id_print_terminals'),
        'print_jobs', 'print_terminals', ['terminal_id'], ['id'], ondelete='RESTRICT',
    )
    op.drop_constraint(op.f('ck_print_jobs_print_job_type'), 'print_jobs', type_='check')
    op.create_check_constraint(
        op.f('ck_print_jobs_print_job_type'), 'print_jobs', f"type IN {_TYPES_NEW}"
    )


def downgrade() -> None:
    op.execute("DELETE FROM print_jobs WHERE type IN ('DRAWER', 'TEST')")
    op.drop_constraint(op.f('ck_print_jobs_print_job_type'), 'print_jobs', type_='check')
    op.create_check_constraint(
        op.f('ck_print_jobs_print_job_type'), 'print_jobs', f"type IN {_TYPES_OLD}"
    )
    op.drop_constraint(
        op.f('fk_print_jobs_terminal_id_print_terminals'), 'print_jobs', type_='foreignkey'
    )
    op.drop_column('print_jobs', 'terminal_id')
    op.drop_column('print_jobs', 'claimed_at')
    op.drop_table('print_terminals')
