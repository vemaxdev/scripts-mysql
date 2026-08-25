"""
Dashboard web para analisar um pn, mostrando de forma visual a "historia"
dele: a caminhada de OFs em manufatura.pn_extrato_cobertura ate chegar (ou
nao) na cobertura do saldo.

Reaproveita a mesma logica/consultas de cobertura.py e analise_pn.py, mas
em vez de devolver so o resultado final, mantem cada linha do extrato como
um evento da timeline (enriquecida com a data real via SD2 quando a
categoria e ROMANEIO/NF, ou com objeto_dezena_atual.de_simul quando ainda
esta pendente).

Uso:
    py -m pip install flask   (se ainda nao instalado)
    py web_analise_pn.py
    -> abre em http://127.0.0.1:5000
"""

import pandas as pd
from flask import Flask, render_template, request
from sqlalchemy import bindparam, text

from analise_pn import passo1_pn
from cobertura import engine

app = Flask(__name__)

REAIS = ("ROMANEIO", "NF")

CATEGORIA_LABEL = {
    "ROMANEIO": "Nota real (romaneio)",
    "NF": "Nota real (NF)",
    "DESCOBERTO_MANUFATURA": "Projeção (manufatura)",
    "DESCOBERTO": "Sem OF definida",
    "IGNORADA": "Ignorada",
    "EDI": "EDI",
}

STATUS_INFO = {
    "COBERTO": {"cor": "verde", "label": "Coberto", "desc": "O saldo desse pn ja foi totalmente atendido."},
    "DESCOBERTO_MANUFATURA": {
        "cor": "azul",
        "label": "Cobertura projetada (manufatura)",
        "desc": "Ha uma OF em manufatura que deve fechar o saldo (data simulada via objeto_dezena_atual), mas ainda nao foi romaneada/faturada.",
    },
    "DESCOBERTO": {"cor": "vermelho", "label": "Descoberto", "desc": "Nao ha OF que garanta quando esse pn sera atendido."},
    "IGNORADA": {"cor": "cinza", "label": "Ignorada", "desc": "A ultima OF do extrato de cobertura foi marcada como ignorada."},
    "EDI": {"cor": "azul", "label": "Cobertura via EDI", "desc": "A cobertura desse pn depende de um EDI ainda nao confirmado como nota real."},
}


def _to_date(value):
    """Normaliza Timestamp/date/None para date puro (ou None)."""
    if value is None or pd.isna(value):
        return None
    return pd.to_datetime(value).date()


def _historico_extrato(pn: str) -> pd.DataFrame:
    """Todas as linhas de pn_extrato_cobertura desse pn, em ordem de id: a
    caminhada de OFs que o processo de extrato fez ate o saldo bater (ou a
    ultima tentativa conhecida, quando nem somando tudo cobre)."""
    stmt = text("""
        SELECT id, ordem_fabricacao AS `of`, categoria, saldo_final_pn, qtd_of
        FROM pn_extrato_cobertura
        WHERE pn = :pn
        ORDER BY id
    """)
    return pd.read_sql(stmt, engine, params={"pn": pn})


def _datas_sd2(ofs: list) -> pd.DataFrame:
    """Data real (SD2) das OFs informadas, mesmo filtro de sempre: oc_linha
    via ordem_fabricacao, cliente Embraer IN (6,7,8), dentro do periodo CFG."""
    if not ofs:
        return pd.DataFrame(columns=["of", "data_cobertura"])
    stmt = text("""
        WITH cfg_islands AS (
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
    return pd.read_sql(stmt, engine, params={"ofs": ofs})


def _datas_simul(ofs: list) -> pd.DataFrame:
    """de_simul (objeto_dezena_atual) das OFs informadas."""
    if not ofs:
        return pd.DataFrame(columns=["of", "de_simul"])
    stmt = text("""
        SELECT `of`, MAX(de_simul) AS de_simul
        FROM objeto_dezena_atual
        WHERE `of` IN :ofs
        GROUP BY `of`
    """).bindparams(bindparam("ofs", expanding=True))
    return pd.read_sql(stmt, engine, params={"ofs": ofs})


def analisar(pn: str):
    df1 = passo1_pn(pn)
    if df1.empty:
        return None

    qtde_saldo = float(df1.iloc[0]["qtde_saldo"])
    stts_sistema = df1.iloc[0]["stts_atendimento"]

    hist = _historico_extrato(pn)

    if hist.empty:
        # pn nem aparece no extrato de cobertura: confia no status do sistema
        # (mesma regra de fallback da view, quando nao ha OF nenhuma conhecida)
        status_final = "COBERTO" if stts_sistema == "COBERTO" else "DESCOBERTO"
        of_final = None
        data_final = None
        acumulado_final = 0.0
        eventos = []
    else:
        ofs_reais = hist.loc[hist["categoria"].isin(REAIS), "of"].tolist()
        ofs_pendentes = hist.loc[~hist["categoria"].isin(REAIS), "of"].tolist()
        datas_reais = _datas_sd2(ofs_reais)
        datas_simul = _datas_simul(ofs_pendentes)
        hist = hist.merge(datas_reais, on="of", how="left").merge(datas_simul, on="of", how="left")

        hoje = pd.Timestamp.now().normalize()
        eventos = []
        for _, row in hist.iterrows():
            eh_real = row["categoria"] in REAIS
            if eh_real:
                data = _to_date(row.get("data_cobertura"))
            else:
                de_simul = pd.to_datetime(row.get("de_simul"), errors="coerce")
                data = _to_date(de_simul) if pd.notna(de_simul) and de_simul >= hoje else None
            eventos.append({
                "tipo": "real" if eh_real else "projetado",
                "of": row["of"],
                "categoria": row["categoria"],
                "categoria_label": CATEGORIA_LABEL.get(row["categoria"], row["categoria"]),
                "data": data,
                "qtde": float(row["qtd_of"]),
                "acumulado": max(qtde_saldo - float(row["saldo_final_pn"]), 0),
                "cobriu": bool(row["saldo_final_pn"] <= 0),
            })

        ultima = hist.iloc[-1]
        ultima_real = ultima["categoria"] in REAIS
        ultima_data = eventos[-1]["data"]

        if ultima_real and ultima_data is not None:
            # achou a nota real na SD2: cobertura confirmada
            status_final = "COBERTO"
            of_final = ultima["of"]
            data_final = ultima_data
            acumulado_final = max(qtde_saldo - float(ultima["saldo_final_pn"]), 0)
        elif not ultima_real:
            # ainda pendente: status = a propria categoria do extrato
            status_final = ultima["categoria"]
            of_final = ultima["of"]
            data_final = ultima_data
            acumulado_final = max(qtde_saldo - float(ultima["saldo_final_pn"]), 0)
        else:
            # categoria ROMANEIO/NF mas a nota nao foi achada na SD2 dentro
            # do periodo: mesmo fallback da view, confia no status do sistema
            status_final = "COBERTO" if stts_sistema == "COBERTO" else "DESCOBERTO"
            of_final = None
            data_final = None
            acumulado_final = 0.0

    status_simplificado = "COBERTO" if status_final == "COBERTO" else "DESCOBERTO"
    comparativo = "OK" if status_simplificado == stts_sistema else "DIVERGENTE"
    percentual = min(100, round((acumulado_final / qtde_saldo) * 100, 1)) if qtde_saldo else 100

    return {
        "pn": pn,
        "qtde_saldo": qtde_saldo,
        "stts_sistema": stts_sistema,
        "status_analise": status_final,
        "status_info": STATUS_INFO.get(status_final, STATUS_INFO["DESCOBERTO"]),
        "comparativo": comparativo,
        "data_cobertura": data_final,
        "of_cobertura": of_final,
        "acumulado_final": acumulado_final,
        "percentual": percentual,
        "linha_do_tempo": eventos,
    }


@app.route("/")
def index():
    pn = request.args.get("pn", "").strip()
    resultado = None
    erro = None
    if pn:
        resultado = analisar(pn)
        if resultado is None:
            erro = f"O pn '{pn}' nao foi encontrado em pn_cobertura_atual."
    return render_template("analise_pn.html", pn=pn, resultado=resultado, erro=erro)


if __name__ == "__main__":
    app.run(debug=True)
