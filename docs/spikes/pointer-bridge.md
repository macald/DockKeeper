# Ponte de cursor — protótipo (spike)

Data: 2026-10-02. Fork: `macald/DockKeeper`. Status: **PROPOSTO**, não executado.
Código: [`pointer-bridge-probe.swift`](pointer-bridge-probe.swift). Nada disto está no aplicativo.

Rótulos: **CONFIRMADO** (medido) · **INFERÊNCIA** · **HIPÓTESE** · **DESCONHECIDO**.

## Motivação

[side-dock-display.md](side-dock-display.md) mostrou que, neste Mac, o Dock Left só
vai para a LG quando a borda esquerda dela está totalmente livre (empilhado ou
diagonal), com Spaces separados ligados ou desligados. **CONFIRMADO** no E1: com o
MacBook em `(-1000, 1080)` ou `(-1400, 1080)`, o Dock Left fica na LG.

A ponte aceita esse arranjo diagonal para o Dock e recria em software a passagem
lateral do arranjo original.

## Mecanismo

- Arranjo temporário (`.forAppOnly`): LG inalterada; MacBook em `(x, 1080)`,
  padrão `x = -1400`.
- `CGEventTap` de sessão, mesmo tipo e máscara do `BottomDockGuardTap`:
  - Empurrar o cursor para a esquerda na borda esquerda da LG o leva para a borda
    direita do MacBook, na altura que o arranjo original implicava (MacBook
    149 pt abaixo do topo da LG).
  - Empurrar para a direita na borda direita do MacBook faz o caminho inverso.
  - Por padrão, a passagem diagonal nativa (faixa compartilhada) é bloqueada,
    por edição da posição do evento, como no bloqueio do Dock inferior.
- Dois métodos de reposicionamento, para comparação: edição de `event.location`
  (padrão) e `CGWarpMouseCursorPosition` (`--warp`).
- APIs públicas, exceto a escrita de orientação do Dock (CoreDock, ADR-003).
- Exige Accessibility para o processo que roda o probe; o probe explica o motivo
  e não abre o pedido sozinho.

## Hipóteses a testar

| # | Hipótese | Como observar | Confirma | Refuta |
|---|---|---|---|---|
| P1 | O Dock Left fica na LG no arranjo da ponte | `dock host after Left` | `external` | `built-in` |
| P2 | Editar `event.location` leva o cursor para outra tela | linhas `bridge #n` seguidas de `landed` | `landed` em todas | `DID NOT LAND`; repetir com `--warp` |
| P3 | A travessia parece natural nos dois sentidos | uso manual em várias alturas | sem saltos ou travamentos perceptíveis | atraso, salto de altura ou cursor preso |
| P4 | Arrastar uma janela pela ponte a leva junto | arrastar pela barra de título | a janela muda de tela | o cursor muda e a janela fica |
| P5 | Arrastar um arquivo pela ponte funciona | Finder para a outra tela | soltura na outra tela | soltura falha ou é cancelada |
| P6 | Clicar no Dock na borda esquerda não aciona a ponte | clicar ícones com x entre 0 e 51 | só a ação do Dock | travessia sem querer |
| P7 | O tap não é desativado pelo sistema | `tap re-enabled` e resumo final | contagem 0 | contagem acima de 0 |

**DESCONHECIDO principal:** P4. Se a janela arrastada não acompanhar o cursor, a ponte
serve só para o cursor e seria preciso outra solução para mover janelas.

**INFERÊNCIA:** com o Dock em ocultação automática, revelar o Dock e atravessar
disputam o mesmo gesto na borda. Este protótipo assume o Dock sempre visível.

## Execução (somente com autorização)

```sh
swiftc docs/spikes/pointer-bridge-probe.swift -o .build/probes/pointer-bridge-probe
.build/probes/pointer-bridge-probe              # somente leitura
.build/probes/pointer-bridge-probe --run=180    # experimento; Ctrl-C restaura
.build/probes/pointer-bridge-probe --run=180 --warp
```

Pré-requisitos: DockKeeper encerrado, duas telas, LG principal, MacBook à esquerda.
Restauração: arranjo original, orientação original e desligamento do tap ao fim do
tempo, com Ctrl-C ou SIGTERM. Se o processo morrer, o arranjo `.forAppOnly` volta
sozinho e o tap deixa de existir; só a orientação do Dock poderia ficar em Left.

## Limitações conhecidas

- Aplicativos e atalhos que usam o arranjo das telas, como "mover para a tela da
  esquerda", verão o MacBook abaixo da LG.
- Para uso diário, o arranjo diagonal teria de ser permanente e a ponte teria de
  rodar sempre. Isso exigiria ADR, atualização do product-scope e decisão do
  proprietário (regras 12–14 do AGENTS.md).

## Execução 1 — edição de `event.location` — 2026-10-02

Autorizada pelo usuário: `--run=180`, Spaces separados **desligados**, DockKeeper
encerrado. Interrompida com Ctrl-C (SIGINT) após ~2 minutos, porque nenhuma
travessia funcionou. O DockKeeper foi reaberto em seguida.

| Item | Resultado |
|---|---|
| Arranjo aplicado | MacBook `(-1400, 1080, 1512, 982)`, LG inalterada |
| P1 — Dock Left no arranjo da ponte | **CONFIRMADO:** LG (`external`), também com Spaces desligados |
| P2 — editar `event.location` atravessa telas | **REFUTADO:** 143 tentativas (113 LG→MacBook, 30 MacBook→LG), 0 chegaram; o evento seguinte continuou na tela de origem |
| Bloqueio da faixa diagonal pela mesma técnica | **Ineficaz:** 144 bloqueios registrados, e o cursor ainda chegou ao MacBook |
| P7 — tap desativado pelo sistema | 0 reativações |
| Restauração | `restored-bounds-match: true`, Bottom confirmado |

**INFERÊNCIA:** a edição de posição funciona para segurar o cursor dentro da mesma
tela (bloqueio do Dock inferior, confirmado no upstream), mas o WindowServer
recalcula a posição a partir do deslocamento e não aceita um salto para uma
região sem contato. O próximo teste é `--warp`, que agora também aplica o
bloqueio com `CGWarpMouseCursorPosition`. P3–P6 ficaram sem avaliação.

## Execução 2 — `--warp` — 2026-10-02

Autorizada pelo usuário: `--run=180 --warp`, Spaces separados desligados,
DockKeeper encerrado e reaberto ao final. Execução completa de 180 s.

| Item | Resultado |
|---|---|
| P1 — Dock Left na LG | **CONFIRMADO** (`external`) |
| P2 — `CGWarpMouseCursorPosition` atravessa telas | **CONFIRMADO, com ressalva:** 134 travessias (66 LG→MacBook, 68 MacBook→LG), 119 chegaram |
| Falhas | 15, todas no sentido MacBook→LG e quase sempre logo após uma chegada: vaivém imediato, a segunda reposição suprimida |
| Arrastando com botão esquerdo | 16 travessias registradas; houve vaivém repetido entre os mesmos pontos |
| Bloqueio da faixa diagonal | 14 retenções |
| P7 — tap desativado | 0 |
| Restauração | `restored-bounds-match: true`, Bottom confirmado |

**INFERÊNCIA:** depois do reposicionamento, o evento seguinte ainda conta como
empurrão contra a borda de chegada, provocando o retorno imediato. Correção
aplicada no protótipo, ainda não testada: chegada 6 pt para dentro da tela e
intervalo de 200 ms entre travessias.

P4 (janela acompanha o arraste) e P5 (arquivo) dependem da observação do usuário.

**Observação do usuário (execução 2):** ao passar da LG para o MacBook, o cursor
voltava para a LG, "como se existisse uma barreira"; o mesmo ao arrastar janelas.
P3–P6 não foram avaliados. Isso confirma o vaivém do registro: o log contou a
chegada (`landed`), mas a travessia de volta disparou em seguida. Portanto, a
contagem de 119 chegadas superestima travessias úteis.

## Execução 3 — `--warp` com chegada 6 pt para dentro e intervalo de 200 ms — 2026-10-02

Autorizada pelo usuário, mesmas condições; 180 s completos, restauração com
`restored-bounds-match: true`, Bottom confirmado, DockKeeper reaberto.

| Item | Registro | Observação do usuário |
|---|---|---|
| Travessias | 30: 15 LG→MacBook, 15 MacBook→LG; 1 não chegou | — |
| P3 — passar o cursor LG→MacBook | **Toda** chegada ao MacBook (x=105) foi seguida de volta a partir de x≈111–112 | "mesmo problema", sensação de barreira |
| P4 — janela | 6 travessias arrastando | "deu uma esbarrada, mas foi" |
| P5 — arquivo do Finder | — | igual à janela |
| P6 — Dock na borda esquerda | — | funcionou normalmente |
| P7 — tap desativado | 0 | — |

**CONFIRMADO:** após cada chegada ao MacBook, o cursor se deslocou para a direita
até a borda (≈6–7 pt) e disparou a volta, mesmo com o intervalo de 200 ms.
**DESCONHECIDO:** se o deslocamento vem do movimento da mão ou de o WindowServer
reposicionar o cursor depois do warp. A correção da execução 3 não resolveu.

Alterações para uma execução 4 (não executada): travessia só depois de empurrar
continuamente a borda por 24 pt (`--pressure=<pt>`), e registro de cada evento
(tempo, posição, dx, dy) durante 1 s após cada travessia, para identificar a causa.

## Execução 4 — `--warp` com resistência de 24 pt e rastreamento — 2026-10-02

Autorizada pelo usuário; 180 s completos, restauração confirmada.

| Item | Registro | Observação do usuário |
|---|---|---|
| P3 — travessia com o mouse | 6 travessias (3 em cada sentido), 0 falhas, nenhum vaivém | "funcionou melhor, atravessou" |
| P4/P5 — janela e arquivo | 4 travessias arrastando | "funcionou como estava" (com esbarrada) |
| P6 — Dock | — | normal |

**CONFIRMADO pelo rastreamento**, em todas as 6 travessias:

- O primeiro evento após o warp carrega como deslocamento o próprio salto
  (por exemplo, `dx=75 dy=930` ao ir da LG para o MacBook). **INFERÊNCIA:** esse
  deslocamento sintético causava o vaivém das execuções 2 e 3; a resistência na
  borda o neutraliza.
- O cursor fica parado por **250–272 ms** depois do warp, embora os eventos
  continuem chegando com `dx` diferente de zero. Isso explica a "esbarrada".
  **INFERÊNCIA (de memória, sem fonte verificada):** é o intervalo padrão de
  supressão de eventos locais, de 0,25 s.

Alteração para a execução 5: `--post` troca o warp por um evento de mouse
sintetizado, de uma fonte com intervalo de supressão zero; o evento original é
descartado. O intervalo original da fonte é restaurado ao terminar.

## Execução 5 — `--post` (evento sintetizado, supressão zero) e resistência de 24 pt — 2026-10-02

Autorizada pelo usuário; 180 s completos. Restauração: `restored-bounds-match: true`,
Bottom confirmado, DockKeeper reaberto. Spaces separados continuavam desligados.

| Item | Registro | Observação do usuário |
|---|---|---|
| Travessias | 33: 17 LG→MacBook, 16 MacBook→LG; 2 arrastando | "funcionou tudo mais fluido" |
| Falhas | 1 falso negativo: um evento já enfileirado chegou antes; o rastreamento mostra o cursor no destino 1 ms depois | — |
| Congelamento após a travessia | **eliminado:** primeiro movimento entre 1 e 14 ms (antes 250–272 ms) | sem esbarrada relatada |
| Bloqueio da faixa diagonal | 27 retenções | — |
| P7 — tap desativado | 0 | — |

**CONFIRMADO neste Mac:** Dock Left na LG + arranjo diagonal + ponte por evento
sintetizado produziram, na avaliação do usuário, travessia fluida do cursor, de
janelas e de arquivos, com o Dock funcionando normalmente.

**Observação:** no primeiro movimento após a travessia, o cursor avança de uma vez
20–90 pt para dentro da tela de destino. O usuário não percebeu como problema.

**Ainda não testado:** repouso/despertar, reconexão da LG, Spaces separados
ligados, tela cheia, Mission Control, compartilhamento de tela, uso prolongado e
custo de CPU. A posição do cursor também não foi testada com alteração de
resolução ou escala.
