"""
Dashboard web para analisar um pn, mostrando de forma visual a "historia"
dele: quais notas reais (SD2) e quais OFs projetadas foram somadas ate
chegar (ou nao) na data de cobertura.

Reaproveita a mesma logica/consultas de cobertura.py e analise_pn.py, mas
em vez de devolver so o resultado final, mantem o detalhe de cada evento
(nota ou OF) para montar a linha do tempo.

Uso:
    py -m pip install flask   (se ainda nao instalado)
    py web_analise_pn.py
    -> abre em http://127.0.0.1:5000
"""

import pandas as pd
from flask import Flask, render_template, request
from sqlalchemy import text

from analise_pn import passo1_pn
from cobertura import engine, passo2_emissao_sd2

app = Flask(__name__)


def _to_date(value):
    """Normaliza Timestamp/date/None para date puro (ou None)."""
    if value is None or pd.isna(value):
        return None
    return pd.to_datetime(value).date()


def montar_historico_real(pn: str, qtde_saldo: float, df_notas: pd.DataFrame):
    """Reproduz o passo 3 (acumulo de notas reais da SD2), mas devolvendo
    cada nota como um evento da linha do tempo, nao so o resumo final."""
    notas = (
        df_notas.dropna(subset=["emissao"])
        .astype({"quantidade": "float64"})
        .groupby(["of", "emissao"], as_index=False)["quantidade"]
        .max()
        .sort_values(["emissao", "of"])
    )

    eventos = []
    acumulado = 0.0
    cobriu_em = None
    for _, row in notas.iterrows():
        acumulado += row["quantidade"]
        cruzou = cobriu_em is None and acumulado >= qtde_saldo
        eventos.append({
            "tipo": "real",
            "of": row["of"],
            "data": _to_date(row["emissao"]),
            "qtde": row["quantidade"],
            "acumulado": acumulado,
            "cobriu": cruzou,
        })
        if cruzou:
            cobriu_em = eventos[-1]

    return eventos, acumulado, cobriu_em


def montar_projecao(pn: str, qtde_saldo: float, leftover: float, ofs_usadas: set, fonte: str = "auto"):
    """Reproduz o passo 4 (projecao via previsao de faturamento e/ou
    manufatura), devolvendo cada OF candidata como evento, mais a
    classificacao final (COB / COMOF / STKSEMOF / SEMOF).

    fonte:
      - "auto": previsao de faturamento (PFAT); se nula/vencida, cai no
        de_simul da manufatura (comportamento padrao, igual ao cobertura.py).
      - "simulado": ignora a previsao de faturamento e usa so o de_simul de
        objeto_dezena_atual (manufatura).
    """
    if fonte == "simulado":
        stmt = text("""
            SELECT
                ODF.`of`,
                ODF.qtde,
                MAX(OBJD.de_simul) AS objd_de_simul
            FROM ordem_fabricacao ODF
            JOIN objeto_dezena_atual OBJD ON OBJD.`of` = ODF.`of`
            WHERE ODF.pn = :pn
            GROUP BY ODF.`of`, ODF.qtde
        """)
        ofs = pd.read_sql(stmt, engine, params={"pn": pn})
    else:
        stmt = text("""
            SELECT
                ODF.`of`,
                ODF.qtde,
                MAX(PFAT.`Emissão`) AS pfat_emissao,
                MAX(OBJD.de_simul) AS objd_de_simul
            FROM ordem_fabricacao ODF
            LEFT JOIN pbi.vwf_previsao_faturamento PFAT ON PFAT.`Nro Doc` = ODF.`of`
            LEFT JOIN objeto_dezena_atual OBJD ON OBJD.`of` = ODF.`of`
            WHERE ODF.pn = :pn
              AND (PFAT.`Nro Doc` IS NOT NULL OR OBJD.`of` IS NOT NULL)
            GROUP BY ODF.`of`, ODF.qtde
        """)
        ofs = pd.read_sql(stmt, engine, params={"pn": pn})

    if ofs.empty:
        return [], [], leftover, "SEMOF" if leftover < qtde_saldo else "COB"

    ofs["qtde"] = ofs["qtde"].fillna(0)

    hoje = pd.Timestamp.now().normalize()
    objd_de_simul = pd.to_datetime(ofs["objd_de_simul"], errors="coerce")
    objd_de_simul = objd_de_simul.where(objd_de_simul >= hoje)

    if fonte == "simulado":
        ofs["data_projecao"] = objd_de_simul
    else:
        pfat_emissao = pd.to_datetime(ofs["pfat_emissao"], errors="coerce")
        pfat_emissao = pfat_emissao.where(pfat_emissao >= hoje)
        ofs["data_projecao"] = pfat_emissao.combine_first(objd_de_simul)

    ofs = ofs[~ofs["of"].isin(ofs_usadas)]

    dated = ofs[ofs["data_projecao"].notna()].sort_values("data_projecao")
    undated = ofs[ofs["data_projecao"].isna()]

    eventos_datados = []
    acumulado = leftover
    status = "DESCOBERTO"
    cobriu_em = None
    for _, row in dated.iterrows():
        acumulado += row["qtde"]
        cruzou = cobriu_em is None and acumulado >= qtde_saldo
        evento = {
            "tipo": "projetado",
            "of": row["of"],
            "data": _to_date(row["data_projecao"]),
            "qtde": row["qtde"],
            "acumulado": acumulado,
            "cobriu": cruzou,
        }
        eventos_datados.append(evento)
        if cruzou:
            status = "COB"
            cobriu_em = evento

    eventos_sem_data = [
        {"tipo": "sem_data", "of": row["of"], "qtde": row["qtde"]}
        for _, row in undated.iterrows()
    ]

    if status != "COB":
        acumulado_total = leftover + ofs["qtde"].sum()
        if dated.empty:
            status = "SEMOF"
        elif acumulado_total >= qtde_saldo:
            status = "COMOF"
        else:
            status = "STKSEMOF"
        acumulado = acumulado_total

    return eventos_datados, eventos_sem_data, acumulado, status


STATUS_INFO = {
    "COBERTO": {"cor": "verde", "label": "Coberto", "desc": "O saldo desse pn ja foi totalmente atendido."},
    "COB": {"cor": "azul", "label": "Cobertura projetada", "desc": "Ainda nao chegou, mas ha OFs com data prevista que fecham o saldo."},
    "COMOF": {"cor": "laranja", "label": "Cobertura parcial (falta OF sem data)", "desc": "Some tudo (com e sem data) e da o saldo, mas parte depende de OF que ainda nao tem data prevista."},
    "STKSEMOF": {"cor": "vermelho", "label": "Insuficiente mesmo somando tudo", "desc": "Mesmo somando todas as OFs pendentes (com e sem data), nao fecha o saldo."},
    "SEMOF": {"cor": "vermelho", "label": "Sem nenhuma OF com data", "desc": "Nenhuma das OFs pendentes desse pn tem data prevista de entrega."},
    "DESCOBERTO": {"cor": "cinza", "label": "Descoberto", "desc": "Nao ha OF nem nota que aponte quando esse pn sera atendido."},
}


def analisar(pn: str, fonte: str = "auto"):
    df1 = passo1_pn(pn)
    if df1.empty:
        return None

    qtde_saldo = float(df1.iloc[0]["qtde_saldo"])
    stts_sistema = df1.iloc[0]["stts_atendimento"]

    df2 = passo2_emissao_sd2([pn])
    eventos_reais, acumulado_real, cobriu_real = montar_historico_real(pn, qtde_saldo, df2)
    ofs_usadas = set(df2.dropna(subset=["emissao"])["of"].unique())

    eventos_projetados, eventos_sem_data, acumulado_final, status_projecao = [], [], acumulado_real, None

    if cobriu_real is not None:
        status_analise = "COBERTO"
        data_cobertura = cobriu_real["data"]
        of_cobertura = cobriu_real["of"]
        acumulado_final = acumulado_real
    elif stts_sistema == "COBERTO":
        status_analise = "COBERTO"
        data_cobertura = None
        of_cobertura = None
        acumulado_final = acumulado_real
    elif stts_sistema == "DESCOBERTO":
        eventos_projetados, eventos_sem_data, acumulado_final, status_projecao = montar_projecao(
            pn, qtde_saldo, acumulado_real, ofs_usadas, fonte=fonte
        )
        status_analise = status_projecao
        cobriu_proj = next((e for e in eventos_projetados if e["cobriu"]), None)
        data_cobertura = cobriu_proj["data"] if cobriu_proj else None
        of_cobertura = cobriu_proj["of"] if cobriu_proj else None
    else:
        status_analise = "DESCOBERTO"
        data_cobertura = None
        of_cobertura = None

    status_simplificado = "COBERTO" if status_analise == "COBERTO" else "DESCOBERTO"
    comparativo = "OK" if status_simplificado == stts_sistema else "DIVERGENTE"

    linha_do_tempo = eventos_reais + eventos_projetados
    percentual = min(100, round((acumulado_final / qtde_saldo) * 100, 1)) if qtde_saldo else 100

    return {
        "pn": pn,
        "fonte": fonte,
        "qtde_saldo": qtde_saldo,
        "stts_sistema": stts_sistema,
        "status_analise": status_analise,
        "status_info": STATUS_INFO.get(status_analise, STATUS_INFO["DESCOBERTO"]),
        "comparativo": comparativo,
        "data_cobertura": data_cobertura,
        "of_cobertura": of_cobertura,
        "acumulado_final": acumulado_final,
        "percentual": percentual,
        "linha_do_tempo": linha_do_tempo,
        "ofs_sem_data": eventos_sem_data,
    }


@app.route("/")
def index():
    pn = request.args.get("pn", "").strip()
    fonte = request.args.get("fonte", "auto")
    if fonte not in ("auto", "simulado"):
        fonte = "auto"
    resultado = None
    erro = None
    if pn:
        resultado = analisar(pn, fonte=fonte)
        if resultado is None:
            erro = f"O pn '{pn}' nao foi encontrado em pn_cobertura_atual."
    return render_template("analise_pn.html", pn=pn, fonte=fonte, resultado=resultado, erro=erro)


if __name__ == "__main__":
    app.run(debug=True)
