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


def passo2_emissao_sd2(pns: list) -> pd.DataFrame:
    """ODF + CFG + SD2: para cada pn, verifica se ha emissao na SD2 no periodo atual.

    Usa ordem_fabricacao (pn -> of) em vez de pn_extrato_cobertura, pois esta
    ultima nao lista o pn quando ele ja foi coberto. O join com a SD2 tambem
    exige numpedcomp/itempedcom = as duas partes de ordem_fabricacao.oc_linha
    (ex: "906245296/00010"), para nao pegar linhas da SD2 do mesmo `of` que
    sejam de outro pedido/item (ex: consumo de material).
    """
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
            PNAT.pn,
            ODF.`of`,
            SD2.emissao,
            SD2.quantidade
        FROM pn_cobertura_atual PNAT
        LEFT JOIN ordem_fabricacao ODF ON ODF.pn = PNAT.pn
        JOIN CFG ON 1 = 1
        LEFT JOIN totvs_sd2 SD2
            ON SD2.`of` = ODF.`of`
           AND SD2.numpedcomp = SUBSTRING_INDEX(ODF.oc_linha, '/', 1)
           AND SD2.itempedcom <> ''
           AND CAST(SD2.itempedcom AS UNSIGNED) = CAST(SUBSTRING_INDEX(ODF.oc_linha, '/', -1) AS UNSIGNED)
           AND SD2.cliente IN (6, 7, 8)
           AND SD2.emissao BETWEEN CFG.data_periodo_inicial_ajustado AND LAST_DAY(CFG.data_periodo_inicial)
        WHERE PNAT.pn IN :pns
        ORDER BY PNAT.pn, SD2.emissao, ODF.`of`
    """).bindparams(bindparam("pns", expanding=True))

    df = pd.read_sql(stmt, engine, params={"pns": pns})
    com_emissao = df[df["emissao"].notna()]
    sem_emissao = len(df) - len(com_emissao)
    print(f"\n=== Passo 2: ordem_fabricacao + totvs_sd2 (primeiros {len(pns)} pn) ===")
    print(com_emissao)
    if sem_emissao:
        print(f"(+ {sem_emissao} OF sem nota no periodo, omitidas)")

    resumo = (
        df.assign(tem_emissao=df["emissao"].notna())
        .groupby("pn")["tem_emissao"]
        .any()
        .reset_index()
    )
    print("\n--- Resumo: pn tem emissao na SD2 no periodo? ---")
    print(resumo)
    return df


def passo3_data_cobertura(df_saldo: pd.DataFrame, df_notas: pd.DataFrame) -> pd.DataFrame:
    """Acumula a quantidade das notas por pn ate atingir o qtde_saldo.

    Uma "nota" e o par (of, emissao); quando ha mais de uma linha na SD2 para
    a mesma nota, usa a maior quantidade (mesmo criterio da view: MAX por
    pn+emissao+of). Soma as notas em ordem de emissao ate o acumulado igualar
    ou superar o qtde_saldo do pn: essa e a data_cobertura. Se nunca atingir,
    o pn fica DESCOBERTO.
    """
    saldo_por_pn = df_saldo.set_index("pn")["qtde_saldo"]

    notas = (
        df_notas.dropna(subset=["emissao"])
        .astype({"quantidade": "float64"})
        .groupby(["pn", "of", "emissao"], as_index=False)["quantidade"]
        .max()
        .sort_values(["pn", "emissao", "of"])
    )
    notas["qtde_acumulada"] = notas.groupby("pn")["quantidade"].cumsum()

    resultados = []
    for pn, qtde_saldo in saldo_por_pn.items():
        pn_notas = notas[notas["pn"] == pn]
        cobertas = pn_notas[pn_notas["qtde_acumulada"] >= qtde_saldo]
        if not cobertas.empty:
            primeira = cobertas.iloc[0]
            resultados.append({
                "pn": pn,
                "qtde_saldo": qtde_saldo,
                "data_cobertura": primeira["emissao"].strftime("%Y-%m-%d"),
                "of_cobertura": primeira["of"],
                "qtde_acumulada": primeira["qtde_acumulada"],
            })
        else:
            resultados.append({
                "pn": pn,
                "qtde_saldo": qtde_saldo,
                "data_cobertura": "DESCOBERTO",
                "of_cobertura": None,
                "qtde_acumulada": pn_notas["qtde_acumulada"].max() if not pn_notas.empty else 0,
            })

    resultado_df = pd.DataFrame(resultados)
    print("\n=== Passo 3: data de cobertura por pn ===")
    print(resultado_df)
    return resultado_df


def passo4_projecao_faturamento(df_passo3: pd.DataFrame, df_notas: pd.DataFrame) -> pd.DataFrame:
    """Para os pn ainda DESCOBERTO, continua acumulando com OFs projetadas.

    Quantidade agora vem de ordem_fabricacao.qtde (nao mais da SD2). A data
    usada e vwf_previsao_faturamento.Emissao (Nro Doc = of); se nula ou no
    passado, cai no fallback objeto_dezena_atual.de_simul (join por of) - se
    esse tambem estiver no passado, nao usa (fica sem data ali). Nao faz
    sentido "cobrir no passado": se a previsao de faturamento venceu e nunca
    virou nota real, ela nao serve mais como projecao. OFs que ja tinham
    nota real (SD2) contabilizada no passo 3 sao excluidas para nao contar
    a mesma quantidade duas vezes. So entram no calculo OFs que existem em
    objeto_dezena_atual (join obrigatorio); OFs fora dessa tabela nao sao
    consideradas nem sequer como "sem data".

    Primeiro tenta cobrir o saldo somando so as OFs COM data, em ordem
    cronologica (status COB, com data_projetada real). Se as OFs com data
    nao bastarem sozinhas, classifica em um dos 3 status abaixo (sem data
    de projecao, pois nao ha como saber quando isso sera coberto):
    - SEMOF: nenhuma OF pendente desse pn tem data, independente da soma
      bater o saldo ou nao.
    - COMOF: ha pelo menos 1 OF com data, e a soma de TODAS as OFs
      pendentes (com + sem data) ja bate o saldo, mas parte necessaria
      vem de OF(s) sem data.
    - STKSEMOF: ha pelo menos 1 OF com data, mas mesmo somando todas as
      OFs pendentes (com + sem data) o total ainda fica abaixo do saldo.
    """
    descobertos = df_passo3[df_passo3["data_cobertura"] == "DESCOBERTO"].copy()
    if descobertos.empty:
        print("\n=== Passo 4: nenhum pn DESCOBERTO para projetar ===")
        return descobertos

    pns = descobertos["pn"].tolist()

    stmt = text("""
        SELECT
            ODF.pn,
            ODF.`of`,
            ODF.qtde,
            MAX(PFAT.`Emissão`) AS pfat_emissao,
            MAX(OBJD.de_simul) AS objd_de_simul
        FROM ordem_fabricacao ODF
        LEFT JOIN pbi.vwf_previsao_faturamento PFAT ON PFAT.`Nro Doc` = ODF.`of`
        LEFT JOIN objeto_dezena_atual OBJD ON OBJD.`of` = ODF.`of`
        WHERE ODF.pn IN :pns
          AND (
            PFAT.`Nro Doc` IS NOT NULL
            OR OBJD.`of` IS NOT NULL
          )
        GROUP BY ODF.pn, ODF.`of`, ODF.qtde
    """).bindparams(bindparam("pns", expanding=True))
    ofs = pd.read_sql(stmt, engine, params={"pns": pns})
    ofs["qtde"] = ofs["qtde"].fillna(0)

    hoje = pd.Timestamp.now().normalize()
    pfat_emissao = pd.to_datetime(ofs["pfat_emissao"], errors="coerce")
    pfat_emissao = pfat_emissao.where(pfat_emissao >= hoje)
    objd_de_simul = pd.to_datetime(ofs["objd_de_simul"], errors="coerce")
    objd_de_simul = objd_de_simul.where(objd_de_simul >= hoje)
    ofs["data_projecao"] = pfat_emissao.combine_first(objd_de_simul)

    ofs_ja_usadas = df_notas.dropna(subset=["emissao"])[["pn", "of"]].drop_duplicates()
    ofs = ofs.merge(ofs_ja_usadas.assign(_usada=True), on=["pn", "of"], how="left")
    ofs = ofs[ofs["_usada"].isna()].drop(columns="_usada")

    ofs = ofs.sort_values(["pn", "data_projecao"], na_position="last")

    resultados = []
    for _, linha in descobertos.iterrows():
        pn = linha["pn"]
        qtde_saldo = linha["qtde_saldo"]
        leftover = linha["qtde_acumulada"]
        pn_ofs = ofs[ofs["pn"] == pn]
        dated = pn_ofs[pn_ofs["data_projecao"].notna()].sort_values("data_projecao")

        status = "DESCOBERTO"
        data_projetada = None
        of_projecao = None
        acumulado = leftover

        # tenta cobrir so com OFs com data, em ordem cronologica
        for _, of_linha in dated.iterrows():
            acumulado += of_linha["qtde"]
            if acumulado >= qtde_saldo:
                of_projecao = of_linha["of"]
                status = "COB"
                data_projetada = of_linha["data_projecao"].strftime("%Y-%m-%d")
                break

        if status == "DESCOBERTO":
            acumulado = leftover + pn_ofs["qtde"].sum()
            if dated.empty:
                status = "SEMOF"
            elif acumulado >= qtde_saldo:
                status = "COMOF"
            else:
                status = "STKSEMOF"

        resultados.append({
            "pn": pn,
            "qtde_saldo": qtde_saldo,
            "qtde_acumulada_final": acumulado,
            "status": status,
            "data_projetada": data_projetada,
            "of_projecao": of_projecao,
        })

    resultado_df = pd.DataFrame(resultados)
    print("\n=== Passo 4: projecao via previsao_faturamento / objeto_dezena_atual ===")
    print(resultado_df)
    return resultado_df


def monta_resultado_final(
    df_passo1: pd.DataFrame, df_passo3: pd.DataFrame, df_passo4: pd.DataFrame
) -> pd.DataFrame:
    """Combina stts_atendimento (do sistema) com a nossa analise (passo 3 + passo 4).

    Regra:
    - stts_atendimento == 'COBERTO': tentamos achar a data via passo 3 (nota
      real na SD2). Nao projeta (passo 4). Se nao achar a nota, confia no
      status do sistema mesmo assim (status_analise = COBERTO) e deixa
      data/of em branco.
    - stts_atendimento == 'DESCOBERTO': o passo 3 ja diz se, na pratica, ja
      foi coberto por uma nota real; se ainda nao foi, usamos o passo 4 para
      projetar quando vai cobrir.

    Cria a coluna `comparativo`: OK quando a nossa analise (simplificada em
    COBERTO/DESCOBERTO) bate com o stts_atendimento do sistema, DIVERGENTE
    caso contrario.
    """
    projecao = df_passo4.set_index("pn") if not df_passo4.empty else None

    resultados = []
    for _, linha in df_passo1.iterrows():
        pn = linha["pn"]
        stts = linha["stts_atendimento"]
        qtde_saldo = linha["qtde_saldo"]

        linha3 = df_passo3[df_passo3["pn"] == pn].iloc[0]
        achou_real = linha3["data_cobertura"] != "DESCOBERTO"

        if achou_real:
            status_nossa = "COBERTO"
            data_nossa = linha3["data_cobertura"]
            of_nossa = linha3["of_cobertura"]
            qtde_nossa = linha3["qtde_acumulada"]
        elif stts == "COBERTO":
            # sistema diz coberto; mesmo sem achar a nota real, confia no
            # status e so deixa a data/of em branco (nao projeta)
            status_nossa = "COBERTO"
            data_nossa = None
            of_nossa = None
            qtde_nossa = linha3["qtde_acumulada"]
        elif projecao is not None and pn in projecao.index:
            p = projecao.loc[pn]
            status_nossa = p["status"]
            data_nossa = p["data_projetada"]
            of_nossa = p["of_projecao"]
            qtde_nossa = p["qtde_acumulada_final"]
        else:
            status_nossa = "DESCOBERTO"
            data_nossa = None
            of_nossa = None
            qtde_nossa = linha3["qtde_acumulada"]

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
    df_passo2 = passo2_emissao_sd2(todos_pns)
    df_passo3 = passo3_data_cobertura(df_passo1, df_passo2)

    # so projeta (passo 4) os pn que o sistema ainda considera DESCOBERTO
    pns_descoberto_sistema = df_passo1.loc[df_passo1["stts_atendimento"] == "DESCOBERTO", "pn"]
    df_passo3_para_projecao = df_passo3[
        df_passo3["pn"].isin(pns_descoberto_sistema) & (df_passo3["data_cobertura"] == "DESCOBERTO")
    ]
    df_passo4 = passo4_projecao_faturamento(df_passo3_para_projecao, df_passo2)

    monta_resultado_final(df_passo1, df_passo3, df_passo4)
