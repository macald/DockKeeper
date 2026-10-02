# Dock lateral no monitor errado — investigação do fork

Data: 2026-10-02. Fork: `macald/DockKeeper`.

## Resultado

**CONFIRMADO:** o Dock à esquerda permanece no MacBook mesmo com a LG como tela
principal e preferida, no macOS 27.0.1 (26A434), Apple M3 Max, Spaces separados
ativados após logout/login. À direita, o Dock aparece na LG.

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
