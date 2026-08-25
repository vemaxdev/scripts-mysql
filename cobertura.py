"""
Script exploratorio para entender, passo a passo, a logica da view
pbi.vwf_cob_real_proj (ver vwf_cob_real_proj.sql).

Cada PASSO reproduz em Python uma parte da query da view, para
inspecionar o resultado intermediario antes de avancar para o proximo.

Dependencias:
    pip install pandas sqlalchemy pymysql python-dotenv

Configuracao da conexao lida do arquivo .env na raiz do projeto
(DB_HOST, DB_PORT, DB_USER, DB_PASS, DB_NAME).
"""

import os
from urllib.parse import quote_plus

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import bindparam, create_engine, text

pd.set_option("display.max_rows", None)
pd.set_option("display.max_columns", None)
pd.set_option("display.width", None)

load_dotenv()

DB_HOST = os.environ["DB_HOST"]
DB_PORT = os.environ.get("DB_PORT", "3306")
DB_USER = os.environ["DB_USER"]
DB_PASS = os.environ["DB_PASS"]
DB_NAME = os.environ["DB_NAME"]

engine = create_engine(
    f"mysql+pymysql://{quote_plus(DB_USER)}:{quote_plus(DB_PASS)}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)


def passo1_pn_cobertura_atual() -> pd.DataFrame:
    """PNAT: PNs, o saldo que precisa ser coberto e o status "oficial" do sistema.

    stts_atendimento vem de pn_situacao_cobertura.situacao (prefixo antes do
    "_", ex: DESCOBERTO_MANUFATURA -> DESCOBERTO), a mesma fonte usada pela
    CTE SIT_ATUAL em vwf_cobertura_pn.sql - nao de
    pn_cobertura_atual.stts_atendimento, que diverge bastante dela.
    """
    query = """
        SELECT
            PNAT.pn,
            PNAT.qtde_saldo,
            SUBSTRING_INDEX(PSC.situacao, '_', 1) AS stts_atendimento
        FROM pn_cobertura_atual PNAT
        LEFT JOIN pn_situacao_cobertura PSC ON PSC.pn = PNAT.pn
        ORDER BY PNAT.pn
    """
    df = pd.read_sql(query, engine)
    print("=== Passo 1: pn_cobertura_atual + pn_situacao_cobertura (pn, qtde_saldo, stts_atendimento) ===")
    print(df)
    return df


def passo2_extrato_cobertura(pns: list) -> pd.DataFrame:
    """pn_extrato_cobertura: linha que fecha a conta de cada pn (MAX id), com a
    OF, categoria (ROMANEIO/NF = cobertura real; DESCOBERTO_MANUFATURA/DESCOBERTO
    = ainda pendente) e saldo_final_pn.

    Usa manufatura.pn_extrato_cobertura.ordem_fabricacao em vez de ordem_fabricacao
    (pn -> of): agora so usamos as OFs que o proprio extrato de cobertura ja
    definiu, sem recalcular por conta propria quais OFs cobrem o pn.
    """
    stmt = text("""
        SELECT PEC.pn, PEC.ordem_fabricacao AS `of`, PEC.categoria, PEC.saldo_final_pn
        FROM pn_extrato_cobertura PEC
        JOIN (
            SELECT pn, MAX(id) AS max_id
            FROM pn_extrato_cobertura
            WHERE pn IN :pns
            GROUP BY pn
        ) M ON M.pn = PEC.pn AND M.max_id = PEC.id
    """).bindparams(bindparam("pns", expanding=True))

    df = pd.read_sql(stmt, engine, params={"pns": pns})
    print(f"\n=== Passo 2: pn_extrato_cobertura, linha que fecha a conta ({len(pns)} pn) ===")
    print(df)
    print("\n--- Resumo: categoria da linha determinante ---")
    print(df["categoria"].value_counts())
    return df


def passo3_data_cobertura(df_extrato: pd.DataFrame) -> pd.DataFrame:
    """Para categoria ROMANEIO/NF (cobertura real), cruza a OF do extrato com a
    SD2 pra achar a data real da nota. O join exige numpedcomp/itempedcom = as
    duas partes de ordem_fabricacao.oc_linha (ex: "906245296/00010"), para nao
    pegar linhas da SD2 do mesmo `of` que sejam de outro pedido/item, e
    cliente IN (6,7,8) = Embraer, dentro do periodo CFG (mesmo filtro de sempre).
    """
    cobertas = df_extrato[df_extrato["categoria"].isin(["ROMANEIO", "NF"])].copy()
    if cobertas.empty:
        print("\n=== Passo 3: nenhum pn com categoria ROMANEIO/NF ===")
        return pd.DataFrame(columns=["pn", "of_cobertura", "data_cobertura"])

    ofs = cobertas["of"].tolist()
    stmt = text("""
        WITH cfg_islands AS (
            -- agrupa execucoes consecutivas (por id) com o mesmo data_periodo_final,
            -- para diferenciar um periodo "de verdade" de um reprocessamento isolado
            SELECT data_periodo_final, MIN(id) AS min_id, MAX(id) AS max_id, COUNT(*) AS cnt
            FROM (
                SELECT id, data_periodo_final,
                       ROW_NUMBER() OVER (ORDER BY id)
                       - ROW_NUMBER() OVER (PARTITION BY data_periodo_final ORDER BY id) AS grp
                FROM manufatura.controle_processamento_cobertura
            ) t
            GROUP BY data_periodo_final, grp
        ),
        cfg_atual AS (
            SELECT data_periodo_inicial, data_periodo_final
            FROM manufatura.controle_processamento_cobertura
            ORDER BY id DESC
            LIMIT 1
        ),
        cfg_ilha_atual AS (
            SELECT min_id, max_id FROM cfg_islands ORDER BY max_id DESC LIMIT 1
        ),
        cfg_anterior AS (
            -- periodo anterior real: a ilha mais recente antes do periodo atual com
            -- pelo menos 10 execucoes seguidas (descarta ruido de reprocessamento)
            SELECT i.data_periodo_final
            FROM cfg_islands i
            JOIN cfg_ilha_atual c ON i.max_id < c.min_id
            WHERE i.cnt >= 10
            ORDER BY i.max_id DESC
            LIMIT 1
        ),
        CFG AS (
            SELECT
                a.data_periodo_inicial,
                -- novo limite inferior: dia seguinte ao fim do periodo anterior (sem overlap)
                DATE_ADD(p.data_periodo_final, INTERVAL 1 DAY) AS data_periodo_inicial_ajustado
            FROM cfg_atual a
            CROSS JOIN cfg_anterior p
        )
        SELECT
            ODF.`of`,
            MAX(SD2.emissao) AS data_cobertura
        FROM ordem_fabricacao ODF
        JOIN CFG ON 1 = 1
        JOIN totvs_sd2 SD2
            ON SD2.`of` = ODF.`of`
           AND SD2.numpedcomp = SUBSTRING_INDEX(ODF.oc_linha, '/', 1)
           AND SD2.itempedcom <> ''
           AND CAST(SD2.itempedcom AS UNSIGNED) = CAST(SUBSTRING_INDEX(ODF.oc_linha, '/', -1) AS UNSIGNED)
           AND SD2.cliente IN (6, 7, 8)
           AND SD2.emissao BETWEEN CFG.data_periodo_inicial_ajustado AND LAST_DAY(CFG.data_periodo_inicial)
        WHERE ODF.`of` IN :ofs
        GROUP BY ODF.`of`
    """).bindparams(bindparam("ofs", expanding=True))
    datas = pd.read_sql(stmt, engine, params={"ofs": ofs})

    resultado_df = (
        cobertas.merge(datas, on="of", how="left")
        .rename(columns={"of": "of_cobertura"})[["pn", "of_cobertura", "data_cobertura"]]
    )
    print("\n=== Passo 3: data real de cobertura via SD2 (so categoria ROMANEIO/NF) ===")
    print(resultado_df)
    return resultado_df


def passo4_projecao_de_simul(df_extrato: pd.DataFrame) -> pd.DataFrame:
    """Para categoria fora de ROMANEIO/NF (ainda pendente: DESCOBERTO_MANUFATURA,
    DESCOBERTO, etc), projeta a data so com a OF do extrato (objeto_dezena_atual.
    de_simul), sem somar outras OFs pendentes do pn. Nao faz sentido "cobrir no
    passado": ignora de_simul anterior a hoje. O status passa a ser a propria
    categoria do extrato.
    """
    pendentes = df_extrato[~df_extrato["categoria"].isin(["ROMANEIO", "NF"])].copy()
    if pendentes.empty:
        print("\n=== Passo 4: nenhum pn pendente para projetar ===")
        return pd.DataFrame(columns=["pn", "of_projecao", "data_projetada", "status"])

    ofs = pendentes["of"].tolist()
    stmt = text("""
        SELECT `of`, MAX(de_simul) AS de_simul
        FROM objeto_dezena_atual
        WHERE `of` IN :ofs
        GROUP BY `of`
    """).bindparams(bindparam("ofs", expanding=True))
    simul = pd.read_sql(stmt, engine, params={"ofs": ofs})

    hoje = pd.Timestamp.now().normalize()
    merged = pendentes.merge(simul, on="of", how="left")
    de_simul = pd.to_datetime(merged["de_simul"], errors="coerce")
    merged["data_projetada"] = de_simul.where(de_simul >= hoje)

    resultado_df = merged.rename(columns={"of": "of_projecao", "categoria": "status"})[
        ["pn", "of_projecao", "data_projetada", "status"]
    ]
    print("\n=== Passo 4: projecao via objeto_dezena_atual.de_simul (so OF do extrato) ===")
    print(resultado_df)
    return resultado_df


def monta_resultado_final(
    df_passo1: pd.DataFrame,
    df_extrato: pd.DataFrame,
    df_passo3: pd.DataFrame,
    df_passo4: pd.DataFrame,
) -> pd.DataFrame:
    """Combina stts_atendimento (do sistema) com a nossa analise (categoria do
    extrato de cobertura + data real via SD2, ou projecao via de_simul).

    Regra, por pn:
    - se a linha determinante do extrato (passo 2) e ROMANEIO/NF, status =
      COBERTO, com a data real vinda do passo 3 (pode ficar sem data se a
      nota nao foi encontrada na SD2 dentro do periodo).
    - senao, se o sistema ja diz COBERTO, mantem COBERTO mas sem data (nao
      projeta - mesma regra da view: confia no status do sistema mesmo sem
      achar a nota real).
    - senao, usa a projecao do passo 4 (status = categoria do extrato, data =
      de_simul se houver e for futura).
    - se o pn nem aparece no extrato, fica DESCOBERTO sem data.

    Cria a coluna `comparativo`: OK quando a nossa analise (simplificada em
    COBERTO/DESCOBERTO) bate com o stts_atendimento do sistema, DIVERGENTE
    caso contrario.
    """
    cobertura = df_passo3.set_index("pn") if not df_passo3.empty else None
    projecao = df_passo4.set_index("pn") if not df_passo4.empty else None
    saldo_final = df_extrato.set_index("pn")["saldo_final_pn"] if not df_extrato.empty else pd.Series(dtype=float)

    resultados = []
    for _, linha in df_passo1.iterrows():
        pn = linha["pn"]
        stts = linha["stts_atendimento"]
        qtde_saldo = linha["qtde_saldo"]

        if cobertura is not None and pn in cobertura.index:
            c = cobertura.loc[pn]
            status_nossa = "COBERTO"
            data_nossa = c["data_cobertura"]
            of_nossa = c["of_cobertura"]
        elif stts == "COBERTO":
            status_nossa = "COBERTO"
            data_nossa = None
            of_nossa = None
        elif projecao is not None and pn in projecao.index:
            p = projecao.loc[pn]
            status_nossa = p["status"]
            data_nossa = p["data_projetada"]
            of_nossa = p["of_projecao"]
        else:
            status_nossa = "DESCOBERTO"
            data_nossa = None
            of_nossa = None

        saldo_f = saldo_final.get(pn, qtde_saldo)
        qtde_nossa = max(qtde_saldo - saldo_f, 0)

        status_simplificado = "COBERTO" if status_nossa == "COBERTO" else "DESCOBERTO"
        comparativo = "OK" if status_simplificado == stts else "DIVERGENTE"

        resultados.append({
            "pn": pn,
            "qtde_saldo": qtde_saldo,
            "stts_atendimento": stts,
            "status_analise": status_nossa,
            "of": of_nossa,
            "data_cobertura": data_nossa,
            "qtde_acumulada": qtde_nossa,
            "comparativo": comparativo,
        })

    resultado_df = pd.DataFrame(resultados)
    print("\n=== Resultado final: stts_atendimento x nossa analise ===")
    print(resultado_df)
    print("\n--- Comparativo (contagem) ---")
    print(resultado_df["comparativo"].value_counts())
    return resultado_df


if __name__ == "__main__":
    df_passo1 = passo1_pn_cobertura_atual()
    todos_pns = df_passo1["pn"].tolist()
    df_extrato = passo2_extrato_cobertura(todos_pns)
    df_passo3 = passo3_data_cobertura(df_extrato)
    df_passo4 = passo4_projecao_de_simul(df_extrato)

    monta_resultado_final(df_passo1, df_extrato, df_passo3, df_passo4)
