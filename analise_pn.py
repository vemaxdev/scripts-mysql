"""
Analisa um unico pn, rodando o mesmo pipeline do cobertura.py (passos 1 a 4
+ comparativo com stts_atendimento) so pra ele.

Uso:
    py analise_pn.py <pn>
    py analise_pn.py            (pede o pn interativamente)
"""

import sys

import pandas as pd
from sqlalchemy import text

from cobertura import (
    engine,
    monta_resultado_final,
    passo2_emissao_sd2,
    passo3_data_cobertura,
    passo4_projecao_faturamento,
)


def passo1_pn(pn: str) -> pd.DataFrame:
    """PNAT: saldo e stts_atendimento so do pn informado."""
    stmt = text("""
        SELECT pn, qtde_saldo, stts_atendimento
        FROM pn_cobertura_atual
        WHERE pn = :pn
    """)
    df = pd.read_sql(stmt, engine, params={"pn": pn})
    print(f"=== Passo 1: pn_cobertura_atual ({pn}) ===")
    print(df)
    return df


def analisar_pn(pn: str) -> pd.DataFrame:
    df1 = passo1_pn(pn)
    if df1.empty:
        print(f"\npn '{pn}' nao encontrado em pn_cobertura_atual.")
        return df1

    df2 = passo2_emissao_sd2([pn])
    df3 = passo3_data_cobertura(df1, df2)
    df4 = passo4_projecao_faturamento(df3, df2)
    resultado = monta_resultado_final(df1, df3, df4)
    return resultado


if __name__ == "__main__":
    pn_informado = sys.argv[1] if len(sys.argv) > 1 else input("pn: ").strip()
    analisar_pn(pn_informado)
