# Dock lateral no monitor errado — investigação do fork

Data: 2026-10-02. Fork: `macald/DockKeeper`.

## Resultado

**CONFIRMADO:** o Dock à esquerda permanece no MacBook mesmo com a LG como tela
principal e preferida, no macOS 27.0.1 (26A434), Apple M3 Max, Spaces separados
ativados após logout/login. À direita, o Dock aparece na LG.

**CONFIRMADO em teste posterior:** com o MacBook virtualmente centralizado
abaixo da LG, o Dock em `Left` passou para a LG. O teste está detalhado abaixo.

**NÃO RESOLVIDO:** posicionar o Dock nativo na borda esquerda interna da LG,
preservando o arranjo atual ou fazendo apenas um pequeno deslocamento vertical.
Os testes refutam os mecanismos abaixo; não provam impossibilidade geral no macOS.

A correção deste fork detecta e informa a falha, em vez de considerar que tornar
a LG principal já comprova a localização do Dock. Não inclui um remanejamento
automático das telas, uma API privada nova nem uma substituição do Dock.

## Arranjo medido

Coordenadas Core Graphics, em pontos, origem no canto superior esquerdo:

| Tela | Principal | Retângulo (x, y, largura, altura) |
|---|---|---|
| LG ULTRAWIDE | Sim | `(0, 0, 2560, 1080)` |
| MacBook integrado | Não | `(-1512, 149, 1512, 982)` |

A preferência salva corresponde à LG. UUIDs e números de série foram omitidos.

## Experimentos com controle e restauração

O aplicativo instalado foi encerrado durante os testes e reaberto ao final.
`side-dock-probe.swift` usa a API CoreDock já adotada pelo projeto. A observação
usa metadados públicos de janelas do processo Dock, sem ler títulos ou pixels.
O canvas na camada 20 corresponde ao retângulo inteiro de uma das telas.
A redução da área útil à esquerda do MacBook foi observada separadamente.

| Experimento | Resultado observado |
|---|---|
| `Left` com ancoragens 1, 2 e 3 | Canvas no MacBook em todos os casos |
| `Right` com ancoragens 1, 2 e 3 | Canvas na LG em todos os casos |
| Leitura de ancoragem após cada escrita | Sempre 2; os valores alternativos não foram aplicados |
| Retorno a `Left`, ancoragem 2 | Canvas voltou ao MacBook |
| Deslocamento vertical do MacBook: -100, -51, +51, +100 e +200 pontos | Canvas continuou no MacBook em todos os casos |
| Restauração | Arranjo original e `Left`, ancoragem 2, confirmados |

Os deslocamentos usaram `CGCompleteDisplayConfiguration(..., .forAppOnly)`,
com restauração explícita ao final e reversão automática ao encerrar o processo.
Nenhuma alteração de arranjo é feita pela versão de produção deste fork.

## Reprodução

```sh
mkdir -p .build/probes
swiftc docs/spikes/side-dock-probe.swift -o .build/probes/side-dock-probe
.build/probes/side-dock-probe
```

O comando acima é somente leitura. `--anchors` testa as posições e ancoragens;
`--layout` testa os pequenos deslocamentos. Ambos exigem encerrar o DockKeeper
antes, restauram o estado ao terminar normalmente e devem ser acompanhados.
Não executar durante alterações manuais de monitor, apresentações ou tela cheia.

## Validação e limites

- Base do upstream: 360 testes aprovados antes das mudanças.
- Fork: **369 testes aprovados**; os testes adicionais cobrem a LG principal com Dock no MacBook, posição
  correta, transições, observação ausente, monitores espelhados e diagnóstico.
- Compilações debug e release aprovadas; verificação de ausência de APIs de rede aprovada.
- Compilação local com assinatura ad-hoc; não é uma distribuição notarizada.
- O diagnóstico compilado detectou `Preferred: LG ULTRAWIDE` e
  `Observed host: Built-in Retina Display`, com aviso de divergência.
- **DESCONHECIDO:** comportamento do detector em outras versões do macOS,
  tela cheia, Mission Control e todas as variações de ocultação automática.
  Sem um canvas inequívoco, o resultado é desconhecido, não sucesso.
- **INFERÊNCIA:** a geometria da borda compartilhada influencia a escolha do
  macOS. Isolar essa causa de uma mudança no macOS 27 exigiria mais controles.

## Controle com telas empilhadas — 2026-10-02

O usuário autorizou um rearranjo temporário maior. O aplicativo de desenvolvimento
foi encerrado durante o teste e reaberto ao final. A LG continuou principal em
`(0, 0, 2560, 1080)`; apenas a origem do MacBook mudou.

| Etapa | MacBook | Posição | Canvas do Dock |
|---|---|---|---|
| Estado inicial | `(-1512, 149, 1512, 982)` | Bottom | LG |
| Controle antes do rearranjo | `(-1512, 149, 1512, 982)` | Left | MacBook |
| Empilhado, aos 2, 5 e 10 segundos | `(524, 1080, 1512, 982)` | Left | LG em todas as leituras |
| Restauração | `(-1512, 149, 1512, 982)` | Bottom | LG |

**CONFIRMADO:** nesse Mac, alterar a geometria e reaplicar Left moveu o Dock
lateral para a LG, sem reiniciar o Dock ou mudar Spaces. A restauração das
coordenadas originais retornou `restored-bounds-match: true`; a posição Bottom,
que estava ativa no início deste teste, também foi restaurada. Uma leitura
independente após reabrir o aplicativo confirmou as coordenadas e Bottom.

**DESCONHECIDO:** o menor deslocamento necessário, se basta eliminar a borda
compartilhada ou se outra propriedade geométrica determina o resultado, e a
estabilidade desse arranjo após repouso/reconexão. Este controle não comprova
uma solução para manter Left na LG com o MacBook virtualmente à esquerda.

Reprodução autorizada: `.build/probes/side-dock-probe --stacked`. A configuração
usa `.forAppOnly` e restaura coordenadas e posição ao terminar. O código é um
experimento; o aplicativo não altera automaticamente o arranjo.

## Segunda opinião e controle de persistência — 2026-10-02

Consulta realizada pelo Claude CLI 2.1.285, modelo confirmado no resultado
`claude-opus-5-5`, com `--effort high` e ferramentas restritas a leitura.
O nome inicialmente solicitado `opus-5.5-high` foi rejeitado pelo CLI;
modelo e esforço foram passados separadamente. A análise não encontrou um
mecanismo conhecido para direcionar o Dock lateral à borda interna, mas isso
não constitui prova de impossibilidade.

O parecer identificou duas limitações do teste empilhado: havia reaplicação de
Left após a mudança de geometria, e Bottom era restaurado imediatamente após
restaurar o arranjo. Isso impedia avaliar se o Dock permaneceria na LG depois
do retorno do MacBook à esquerda.

O novo modo experimental `--hysteresis` isolou ambas as variáveis. O aplicativo
foi encerrado durante o teste, mantendo Spaces separados ativados:

| Etapa | Orientação | Canvas observado |
|---|---|---|
| Arranjo original, antes de empilhar | Left | MacBook |
| Empilhado sem reescrever orientação, aos 2, 5 e 10 s | Left | LG |
| Arranjo original restaurado sem reescrever orientação, aos 2, 5, 10 e 30 s | Left | MacBook |
| Restauração final | Bottom, como no início | LG |

**CONFIRMADO:** a mudança de geometria, sem reaplicação de Left, foi suficiente
para transferir o Dock para a LG. Ao restaurar o arranjo original, ele voltou
ao MacBook até a primeira leitura, em 2 segundos. A hipótese de conservar o
Dock na LG após esse rearranjo temporário não funcionou neste teste.
As coordenadas originais foram restauradas (`restored-bounds-match: true`),
o aplicativo foi reaberto e uma leitura independente confirmou Bottom e o
arranjo original.

**HIPÓTESE PROPOSTA, testada posteriormente abaixo:** deixar apenas um trecho curto da borda compartilhado,
por exemplo MacBook em `(-1512, 880, 1512, 982)`, preservando 200 pontos de
passagem lateral. Isso exige deslocar o MacBook 731 pontos para baixo em relação
ao original, portanto não equivale ao pequeno ajuste inicialmente aceito.
Nenhuma alteração permanente foi aplicada. O rearranjo parcial ainda não tinha
sido aplicado naquele momento.

Uma folga horizontal de 1 ponto não é solução assegurada pela API pública:
a [documentação de CGConfigureDisplayOrigin](https://developer.apple.com/documentation/coregraphics/cgconfiguredisplayorigin(_:_:_:_:))
informa que as origens são ajustadas para evitar sobreposição ou espaços entre
telas. Esse comportamento foi verificado na documentação, não em novo teste.

## Controle com apenas 200 pontos de borda compartilhada — 2026-10-02

Após autorização do usuário, o modo experimental `--partial` manteve a LG
principal em `(0, 0, 2560, 1080)` e deslocou o MacBook para
`(-1512, 880, 1512, 982)`. As coordenadas solicitadas foram confirmadas após a
aplicação. O aplicativo ficou encerrado durante o teste.

**CONFIRMADO:** o Dock Left continuou no MacBook em todas as leituras:

- Aos 2, 5 e 10 segundos após alterar apenas a geometria.
- Aos 2 e 5 segundos após reaplicar explicitamente Left nesse arranjo.

Portanto, deixar somente 200 pontos compartilhados não resolveu neste Mac.
O resultado não prova qual regra interna o macOS aplica nem exclui todas as
outras geometrias possíveis.

O arranjo original foi restaurado (`restored-bounds-match: true`), junto com
Bottom, ativo no início. O aplicativo de desenvolvimento foi reaberto; uma
leitura independente confirmou o arranjo original, Bottom e o estado do
aplicativo sem divergência. Nenhuma mudança permanente foi aplicada.

## E0 e E1 — dimensão do Dock lateral e arranjo diagonal — 2026-10-02

Autorizados pelo usuário. Novos modos do probe: `--measure` (aplica Left por 6 s,
restaura a orientação) e `--diagonal=<x>` (MacBook abaixo da LG, borda superior
do MacBook encostada na inferior da LG, origem `(x, 1080)`). O DockKeeper ficou
encerrado e foi reaberto ao final.

**Método de leitura:** `CoreDockGetRect` dentro do processo que escreve a
orientação ficou desatualizado, como já registrado no spike de separate Spaces.
As dimensões abaixo vêm de leituras em **processo novo**, feitas durante cada
etapa; o canvas na camada 20 continuou sendo o indicador de tela hospedeira.

### E0 — dimensão do Dock lateral

| Estado | `CoreDockGetRect` (processo novo) |
|---|---|
| Bottom, LG | `(561, 1015, 1438, 65)` |
| Left, MacBook | `(-1512, 199, 48, 914)` |
| Left, LG (durante E1) | `(0, 53, 51, 1003)` |

**CONFIRMADO:** na LG, o Dock lateral ocupa y 53–1056 de 1080 pontos. Por isso,
o teste de 200 pontos compartilhados (y 880–1080) **não** refutou a hipótese de
que importa o trecho de borda ocupado pelo Dock: esse trecho ficava atrás do Dock.

### E1 — MacBook na diagonal, abaixo e à esquerda

| MacBook | Passagem para a LG | Sem reescrever (2, 5, 10 s) | Após reaplicar Left (2, 5 s) |
|---|---|---|---|
| `(-1000, 1080, 1512, 982)` | 512 pt da borda inferior da LG | LG | LG |
| `(-1400, 1080, 1512, 982)` | 112 pt da borda inferior da LG | LG | LG |

Controle antes de cada mudança: Left no arranjo original → MacBook. Restauração:
`restored-bounds-match: true`, Bottom confirmado em leitura independente.

**CONFIRMADO:** neste Mac, o MacBook ser a tela mais à esquerda não basta para
hospedar o Dock Left. A regra "tela mais à esquerda" está refutada aqui, como no
H2 do upstream.

**INFERÊNCIA:** os resultados são compatíveis com duas regras ainda não
separadas: (a) a borda esquerda da tela precisa estar totalmente livre; (b) só
precisa estar livre o trecho ocupado pelo Dock. Em ambas, a tela principal é
preferida entre as candidatas.

**PRÓXIMO TESTE DISCRIMINANTE (não executado):** com Dock lateral de altura
reduzida, deixar o trecho compartilhado fora dele. A regra (b) prevê LG; a (a)
prevê MacBook.

## E3a — borda compartilhada fora da faixa do Dock — 2026-10-02

Autorizado pelo usuário. Novo modo `--at=<x>,<y>` do probe. O MacBook ficou à
esquerda da LG, compartilhando apenas um trecho fora da faixa medida do Dock
Left na LG (y 53–1056). DockKeeper encerrado durante o teste e reaberto ao final.

| MacBook | Trecho compartilhado da borda esquerda da LG | Sem reescrever (2, 5, 10 s) | Após reaplicar Left (2, 5 s) |
|---|---|---|---|
| `(-1512, -935, 1512, 982)` | y 0–47, acima do Dock | MacBook | MacBook |
| `(-1512, 1058, 1512, 982)` | y 1058–1080, abaixo do Dock | MacBook | MacBook |

Coordenadas efetivas confirmadas em leitura independente; restauração com
`restored-bounds-match: true` e Bottom confirmado.

**CONFIRMADO:** neste Mac, compartilhar apenas um trecho da borda esquerda da LG
fora da faixa ocupada pelo Dock ainda deixa o Dock Left no MacBook. A regra
"basta liberar o trecho do Dock" está refutada para a faixa medida.

**INFERÊNCIA:** todos os resultados são compatíveis com "a borda lateral precisa
estar totalmente livre de contato com outra tela; entre as candidatas, a
principal é preferida". Sob essa regra, nenhum arranjo com passagem lateral
entre o MacBook e a borda esquerda da LG hospeda o Dock Left na LG.

**HIPÓTESE RESIDUAL, baixa probabilidade:** uma margem interna maior que 6 pt em
torno do Dock. Testá-la exigiria reduzir o Dock (preferência `tilesize`).

**AINDA NÃO TESTADO:** "Displays have separate Spaces" desligado.

## E2 — "Displays have separate Spaces" desligado — 2026-10-02

O usuário desligou a opção em System Settings e fez logout/login. Antes do teste:
`com.apple.spaces spans-displays = 1`, arranjo original confirmado (LG principal
em `(0, 0, 2560, 1080)`, MacBook em `(-1512, 149, 1512, 982)`) e Dock em Bottom
na LG. DockKeeper encerrado durante o teste e reaberto ao final.
Procedimento: `side-dock-probe --measure --hold=30`.

| Momento | Canvas na camada 20 | `CoreDockGetRect` (processo novo) |
|---|---|---|
| Bottom, antes | LG | `(561, 1015, 1438, 65)` |
| Left, 2, 6 e 30 s | MacBook | `(-1512, 167, 49, 945)` aos ~4, ~16 e ~29 s |
| Restauração | LG | Bottom confirmado |

**CONFIRMADO:** com Spaces unificados, o Dock Left também fica no MacBook neste
arranjo. O retângulo mais alto (945 contra 914 pontos) é compatível com a
ausência da barra de menus no MacBook nesse modo; o canvas de tela inteira
continuou presente, então o detector também funcionou nesse modo.

**Conclusão da investigação nativa:** nenhum mecanismo testado (tela principal,
ancoragem, deslocamento vertical, borda compartilhada parcial, trecho fora do
Dock, Spaces separados ou unificados) coloca o Dock Left na LG enquanto o MacBook
toca a borda esquerda dela. O Dock só foi para a LG quando essa borda ficou
totalmente livre: empilhado ou diagonal. Isso não prova impossibilidade em
outras versões do macOS ou por APIs não testadas.

A opção "Displays have separate Spaces" permaneceu **desligada** ao final deste
teste, aguardando decisão do usuário.
