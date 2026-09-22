-- pbi.vw_status_of_nf fonte

CREATE OR REPLACE
ALGORITHM = UNDEFINED VIEW `pbi`.`vw_status_of_nf` AS with `base` as (
select
    max(`SF2`.`numero`) AS `nf`,
    `SD2`.`of` AS `of`,
    `SD2`.`numpedcomp` AS `oc`,
    `SD2`.`itempedcom` AS `linha`,
    max(`SD2`.`cliente`) AS `cliente`,
    max(`SD2`.`quantidade`) AS `qtd`,
    max(`IPA`.`qtd_recebida`) AS `qtd_recebida`,
    max(`IPA`.`qtde`) AS `qtde_poack`,
    coalesce(max(`ROM`.`romaneio`), NULL) AS `romaneio`,
    coalesce(max(`EDI`.`house`), NULL) AS `house`,
    max(`SF2`.`serie_docto`) AS `serie_docto`,
    max(`SEFAZ`.`tipo`) AS `sefaz_tipo`
from
    (((((((`totvs_sf2` `SF2`
join `totvs_sd2` `SD2` on
    (((`SD2`.`num_docto` = `SF2`.`numero`) and (`SD2`.`tipo_saida` in (501,502)))))
left join `item_poack_atual` `IPA` on
    (((`IPA`.`po` = `SD2`.`numpedcomp`) and (`IPA`.`linha` = `SD2`.`itempedcom`))))
left join `item_romaneio` `IRO` on
    ((`IRO`.`chavenf` = `SF2`.`chave_nfe`)))
left join `romaneio` `ROM` on
    ((`ROM`.`romaneio` = `IRO`.`romaneio`)))
left join `edi`.`etiqueta` `EDI` on
    ((`EDI`.`nf` = `SF2`.`numero`)))
left join `totvs_sf3` `SF3` on
    ((`SF3`.`nota_fiscal` = `SF2`.`numero`)))
left join `sefaz_status` `SEFAZ` on
    ((`SEFAZ`.`codigo` = `SF3`.`retorno_sefa`)))
group by
    `SD2`.`of`,
    `SD2`.`numpedcomp`,
    `SD2`.`itempedcom`),
`windowed` as (
select
    `b`.`nf` AS `nf`,
    `b`.`of` AS `of`,
    `b`.`oc` AS `oc`,
    `b`.`linha` AS `linha`,
    `b`.`cliente` AS `cliente`,
    `b`.`qtd` AS `qtd`,
    `b`.`qtd_recebida` AS `qtd_recebida`,
    `b`.`qtde_poack` AS `qtde_poack`,
    `b`.`romaneio` AS `romaneio`,
    `b`.`house` AS `house`,
    `b`.`serie_docto` AS `serie_docto`,
    `b`.`sefaz_tipo` AS `sefaz_tipo`,
    sum(`b`.`qtd`) OVER (PARTITION BY `b`.`oc`,
    `b`.`linha` ) AS `soma_total`,
    sum(`b`.`qtd`) OVER (PARTITION BY `b`.`oc`,
    `b`.`linha`
ORDER BY
    `b`.`nf` ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS `soma_cumulativa`
from
    `base` `b`)
select
    `windowed`.`of` AS `of`,
    `windowed`.`oc` AS `oc`,
    `windowed`.`linha` AS `linha`,
    `windowed`.`nf` AS `nf`,
    `windowed`.`qtd` AS `qtd_of`,
    `windowed`.`soma_cumulativa` AS `soma_cumulativa`,
    `windowed`.`qtd_recebida` AS `qtd_recebida`,
    `windowed`.`qtde_poack` AS `qtde_poack`,
    `windowed`.`romaneio` AS `romaneio`,
    `windowed`.`house` AS `house`,
    if((`windowed`.`serie_docto` = '001'), `windowed`.`sefaz_tipo`, if((`windowed`.`serie_docto` = '1'), 'AUTORIZADA', 'DESCONHECIDO')) AS `status_sefaz`,
    if((`windowed`.`cliente` in (6, 7, 8, 147)),(case when (`windowed`.`qtd_recebida` is null) then 'ENTREGUE' when (`windowed`.`soma_total` > `windowed`.`qtde_poack`) then 'QTDE. DIVERGENTE' when (`windowed`.`house` is null) then 'AGUARD. EDI' when (`windowed`.`romaneio` is null) then 'AGUARD. EMBARQUE' when (`windowed`.`soma_cumulativa` <= `windowed`.`qtd_recebida`) then 'ENTREGUE' else 'AGUARD. MOV101' end), if((`windowed`.`romaneio` is null), 'AGUARD. EMBARQUE', 'ENTREGUE')) AS `status_nf`
from
    `windowed`
order by
    `windowed`.`oc`,
    `windowed`.`linha`,
    `windowed`.`nf`;