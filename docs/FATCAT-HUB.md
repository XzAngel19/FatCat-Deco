# Fat Cat — menú vacío, listo para llenar

El shell del menú que subiste (`cule.txt`), sin una sola línea de Illegal Soccer.
El GUI es el mismo de arriba a abajo — ventana arrastrable, pestañas con
indicador animado, tarjetas con ripple, toggles, sliders, ciclos, buscador,
toasts, config, minimizar, resize — y todo lo que era del juego se fue.
Las pestañas están vacías a propósito: **el menú no registra ningún módulo**.

```
src/FatCatHub.lua           la ventana: shell, componentes, API
src/FatCatInit.lua          el bootstrapper del proyecto
src/FatCatHub.bundle.lua    generado por tools/build_bundle.py
src/project/*.lua           los 20 módulos del proyecto
src/FatCatHub.project.lua   las tres pestañas del decompiler sobre el shell
src/FatCatHub.loader.lua    loader de una línea
tools/fatchub/              harness: mock de Roblox, asserts, render PNG
docs/FATCAT-HUB.md          esto
```

`src/FatCatHub.lua` sigue siendo la ventana y la única parte que los 94 asserts
y la auditoría de diseño miden. El proyecto (los 20 módulos) se monta encima
vía `Hub:Mount`, así que las dos mitades comparten tabs, toasts, búsqueda y
teardown en vez de duplicarlos.

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/main/src/FatCatHub.loader.lua"))()
```

Ojo con la URL: **`main` todavía no tiene `src/`**, así que ese archivo solo
existe en la rama de trabajo. Mientras no esté mergeado:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/arena/292e8b51-fatcat-deco/src/FatCatHub.loader.lua"))()
```

El loader, una vez que corre, resuelve el resto solo: prueba `main` primero y
luego la rama de trabajo, y se queda con la primera respuesta que de verdad
parezca la librería. Si el menú acaba en otra rama:

```lua
_G.FatCatHubBranch = "mi/rama"
loadstring(...)()
```

Qué hace, en orden: baja `src/FatCatHub.bundle.lua` (los 20 módulos del
proyecto más el bootstrapper y el shell, ya concatenados), lo compila (con la
línea exacta y dos de contexto si hay error de sintaxis), lo ejecuta —lo que
corre `FatCatInit` y arma las 7 pestañas— y devuelve `_G.FatCatHub`. Rechaza
páginas HTML, cuerpos truncados y archivos que no son el bundle antes de
intentar compilar nada. Para cerrarlo:

```lua
getgenv().FatCatProjectUnload()
```

El bundle se regenera con `python3 tools/build_bundle.py`; `tools/validate.sh`
falla si `src/FatCatHub.bundle.lua` no coincide con sus fuentes, así que un
cambio en un módulo sin regenerar no puede llegar a una rama.

Diagnóstico etapa por etapa: `_G.FatCatHubVerbose = true`.

También funciona pegado directo en el executor, sin loader.

## Llenar el menú

Todo va dentro de `Hub:Mount`, que corre **después** de que la ventana exista:

```lua
local Hub = _G.FatCatHub

Hub:Mount(function(hub, window)
    local Combat = window:AddTab("Combat")
    local box = Combat:Section("Aim")
    box:Toggle({ Text = "Silent Aim", Flag = "silentAim" })
end)
```

`Hub:Init()` construye la ventana y borra lo que hubiera dentro; `Hub:Mount()`
añade sin tirar nada y **se vuelve a ejecutar** en cada rebuild, así que el
contenido del juego sobrevive a un cambio de resolución o de pestañas.

Dos formas de retrasar la ventana, y cuál usar:

| Cómo | Cuándo sirve |
| --- | --- |
| `_G.FatCatDeferBoot = true` antes de correr el chunk | un loader que no puede tocar `Hub` todavía |
| `Hub.deferBoot = true` | código que ya tiene el Hub en la mano |

Con cualquiera de las dos, nada construye la ventana hasta el primer
`Hub:Init()`/`Hub:Mount()`. El bundle usa la global: `FatCatInit` la levanta
antes de ejecutar el shell y `FatCatMenu` nombra las 7 pestañas antes de
montarlas, así que la ventana nace ya con la estructura final y nunca hay un
`"Main"` vacío de por medio.

### Referencia de componentes

```lua
local Hub = _G.FatCatHub
local Window = Hub._window

-- Pestañas: la primera existe ("Main"). Se pueden añadir más en caliente.
local Combat = Window:AddTab("Combat")

-- Sección: dos columnas por defecto, `2` para la columna derecha.
local box = Combat:Section("Aim")
local side = Combat:Section("Extras", 2)

box:Toggle({ Text = "Silent Aim", Flag = "silentAim", Default = false,
             Description = "Usa el rayo de la cámara",
             Callback = function(on) print("silent aim", on) end })

sliders:Slider({ Text = "FOV", Min = 0, Max = 180, Default = 90, Decimals = 0,
                 Flag = "fov", Suffix = " deg",
                 Callback = function(v) print(v) end })

box:Dropdown({ Text = "Part", Options = { "Head", "Torso" }, Flag = "part" })
box:Cycle({ Text = "Mode", Options = { "Auto", "Manual" }, Flag = "mode" })
box:Input({ Text = "Webhook", Placeholder = "https://...", Flag = "webhook" })
box:Keybind({ Text = "Panic", Flag = "panic", Default = "Q",
              OnKey = function() print("panic") end })
box:Button({ Text = "Apply", Callback = function() end, Danger = false })
box:Color({ Text = "Tint", Flag = "tint" })
box:Label("Texto explicativo envuelto en varias líneas.")

-- Grupo colapsable: las filas siguientes entran hasta EndGroup().
box:Group({ Text = "Avanzado" })
box:Slider({ Text = "Smooth", Min = 0, Max = 1, Default = 0.3, Decimals = 2, Flag = "smooth" })
box:EndGroup()
```

Cada componente devuelve su tarjeta (el `Frame`/`TextButton`) por si hace falta
moverla, ocultarla o colgarle algo.

### Flags y estado

Cada fila con `Flag` escribe en tres tablas:

| Tabla | Contenido |
| --- | --- |
| `Hub.Values[flag]` | valor actual (`boolean`, número, string, `Color3`) |
| `Hub.Defaults[flag]` | valor de arranque |
| `Hub.Setters[flag]` | `function(value, silent)` — aplica y llama al callback |

```lua
Hub.Setters.silentAim(true)      -- dispara el callback
Hub.Setters.fov(120, true)       -- aplica sin callback
```

### Persistencia

```lua
Hub:Save(true)     -- FatCatHub/config.json  (notifica el resultado)
Hub:Load(true)
Hub:Reset(true)
Hub:Copy()         -- JSON al portapapeles
```

`Save`/`Load` usan `writefile`/`readfile` si el executor los expone; si no,
avisan en un toast y no rompen nada.

### Ventana

```lua
Hub:Toggle()            -- igual que la tecla del menú
Hub:Minimize()
Hub:SelectTab("Combat")
Hub:SetAccent(Color3.fromRGB(120, 180, 255))  -- recolorea todos los degradados
Hub:Notify("Listo", "success", "detalle opcional")
Hub:Unload()
```

Teclas: `RightShift` abre/cierra, `Ctrl+H` muestra u oculta la fila de atajos,
y cada `Keybind` responde a su tecla.

## Qué cambió respecto al original

Bugs reales encontrados y corregidos (cada uno verificado por el harness):

| # | Bug | Efecto |
| --- | --- | --- |
| 1 | `retween` no guardaba el tween que creaba | hover rápido dejaba dos tweens peleando por la misma propiedad y la fila se quedaba pegada en el color de hover |
| 2 | El header de un grupo se adoptaba a sí mismo | el botón "Show options" desaparecía al colapsar |
| 3 | El grupo anterior seguía abierto al abrir el siguiente | las filas nuevas entraban en el grupo viejo |
| 4 | `for offset, alpha in { {2, .86}, ... }` | recorría el array: `offset` era la sub-tabla y `alpha` un string. La sombra salía con `BackgroundTransparency` basura |
| 5 | El buscador solo miraba el nombre interno | buscar "Silent Aim" no encontraba la fila con flag `silentAim` |
| 6 | El buscador resucitaba filas de grupos colapsados | al borrar la búsqueda aparecían filas que debían seguir ocultas |
| 7 | `NumberSequence.new(1, 0.2, 1)` en el divisor | constructor inválido: 3 números donde van 1, 2 o keypoints |
| 8 | La fila de atajos se dibujaba encima del contenido | tapaba la última fila de cada pestaña |
| 9 | `Window:Toggle` y `Hub:Toggle` no existían con el nombre que usa el loader | `attempt to call missing method 'Toggle'` |
| 10 | El chip de keybind era invisible (`element` + hairline) | no se veía dónde hacer clic para rebindear |
| 11 | **La librería construía la ventana al cargar** | cualquier cosa que un proyecto añadiera después necesitaba `Hub:Init()`, que tira la ventana y con ella las filas ya puestas. Ahora `Hub:Mount` |
| 12 | **El loader apuntaba a `main`** | `main` no tiene `src/`: 404 disfrazado de error de sintaxis. Ahora recorre ramas y valida la respuesta |
| 13 | **El loader partía líneas con `gmatch("[^\n]*\n?")`** | el patrón acepta la cadena vacía → bucle infinito. Ahora `(source .. "\n"):gmatch("(.-)\n")` |
| 14 | **El hotkey usaba la `window` capturada en el closure** | tras un rebuild esa ventana está muerta y RightShift dejaba de responder. Ahora llama a `Hub:Toggle()`, que resuelve `_window` en el momento |
| 15 | **Solo `RightShift`** | un teclado de portátil no tiene shift derecho: el menú parecía roto. Ahora `menuKey` acepta una lista |
| 16 | **`Ctrl+H` exigía `LeftControl`** | con el control derecho no pasaba nada. Ahora cualquiera de los dos, y comparando por `KeyCode.Name` |
| 17 | **Una tecla consumida por el juego fallaba en silencio** | indistinguible de un hotkey roto. Ahora avisa con un toast |
| 18 | **La sombra vivía suelta en el ScreenGui** | al arrastrar o ocultar la ventana las capas se quedaban atrás: un rectángulo semi-transparente "plasmado" en el mapa, y RightShift parecía no funcionar porque el fantasma seguía ahí. Ahora las tres capas cuelgan de un host que espeja `Position`, `Size` y `Visible` del frame |
| 19 | **El closure de listening del keybind nunca soltaba `Hub._listening`** | tras rebindear una vez, cada tecla siguiente (RightShift incluido) se la comía el chip viejo y el hotkey moría hasta recargar. Ahora el closure y el dispatch limpian el slot |
| 20 | **El título decía `FatCat Hub`** | el producto se llama **Fat Cat**, con espacio y sin "Hub". Y el punto de la barra es la luz de inyección: verde (`THEME.positive`), nunca gris |
| 21 | **Líneas semi-transparentes sueltas arriba y en la esquina** | el sheen blanco, el hairline sobre las pestañas y los tres grips del resize se veían como basura semi-transparente (y el sheen asomaba cuadrado por la esquina redondeada). Todo eso ahora es transparente sí o sí: la barra no lleva overlay y la esquina de resize no dibuja nada |
| 22 | **Buscador mínimo** | ahora lleva lupa dibujada, botón `×` para limpiar, Escape que vacía y suelta el foco, y se ensancha hacia la izquierda al enfocar sin mover los botones de la barra |

Los tres primeros de esta tanda salieron del harness nuevo, no del original.

Mejoras visuales:

- **Contraste**: fondo `26→12`, tarjetas `38`, sección `17`, contorno `104`.
  El original se leía como una losa negra.
- **Hover honesto**: la tarjeta aclara y el borde se enciende, en vez del salto
  de transparencia `0.35 ↔ 0.65`.
- **Sombra real**: tres capas desplazadas detrás de la ventana, colgadas de un
  host invisible que espeja el frame: se mueve al arrastrar, encoge al
  minimizar y desaparece al ocultar la ventana.
- **Barra de título limpia**: sin sheen ni hairline semi-transparente; el punto
  de marca es verde (inyección correcta) y respira sin apagarse.
- **Buscador**: lupa dibujada, `×` para limpiar, Escape para vaciar y soltar el
  foco, y expansión hacia la izquierda al enfocar.
- **Tipografía**: `Gotham` / `GothamMedium` / `GothamBold` (el original mezclaba
  SourceSans con pesos inconsistentes).
- **Columnas exactas**: el cálculo viejo dejaba la columna derecha más angosta
  por el gutter; ahora ambas miden igual.
- **Sliders con sufijo**: "70 deg" ya no se corta.
- **Fila de atajos propia** en el pie, con `Ctrl+H`.
- **Dropdown nuevo** (no existía): lista nativa, máximo 4 filas visibles, cierra
  al elegir o al cambiar de pestaña.
- **`Description`** opcional en toggles: segunda línea en gris.
- **`Label` y `Divider`** para texto y separadores.
- **Clamp al viewport**: al arrastrar fuera de pantalla o cambiar de resolución,
  la ventana se reacomoda.
- **`SetAccent`**: recolorea todos los degradados vivos de una.

## Ventanas del decompiler

`src/FatCatHub.project.lua` trae tres pestañas además de `Main`:

| Pestaña | Qué hace | Sin executor completo |
| --- | --- | --- |
| **Decompiler** | lista los scripts que el executor deja ver y pide `decompile()` al abrir uno | dice "no disponible" y no rompe |
| **Executor** | 22 sondas: `decompile`, `getscripts`, `getgc`, `hookfunction`, `gethui`… | lista en "Faltan" lo que no responde |
| **Hooks** | RemoteSpy sobre `__namecall`, apagado por defecto | avisa y deja el toggle en off |

Una sonda importa más que un `typeof`: `hookfunction` puede existir y reventar
al llamarla, y para FatCat eso la hace inservible. Cada sonda se prueba en
`pcall` y el resultado se muestra con punto verde o rojo.

El spy **solo lee**: llama siempre al original y nunca bloquea ni modifica una
llamada. Se instala únicamente al encender el toggle, nunca al cargar.

## Atajos

| Atajo | Acción |
| --- | --- |
| `RightShift` / `LeftShift` | mostrar u ocultar el menú |
| `Ctrl` (izq. o der.) + `H` | mostrar u ocultar la fila de atajos |

Si el juego se queda con la tecla (chat abierto, un `TextBox` con foco), el menú
no se abre **y aparece un toast** diciéndolo, en vez de quedarse en silencio.
Para diagnosticar desde la consola: `_G.FatCatHub._lastKey` y
`_G.FatCatHub._lastKeyProcessed`.

## Verificación

```bash
bash tools/luau/setup.sh            # toolchain (una vez)
python3 tools/build_bundle.py       # regenera src/FatCatHub.bundle.lua
bash tools/test_fatchub.sh          # 94 asserts de librería + 16 del proyecto
bash tools/test_fatchub_loader.sh   # 57 asserts del loader, sin red
bash tools/test_fatchub_bundle.sh   # 100 asserts sobre el proyecto ensamblado
bash tools/design.sh                # build/FatCatHub.png + auditoría
bash tools/design.sh --project      # las pestañas del decompiler
bash tools/validate.sh              # todo lo anterior + el resto del repo
```

El arnés del bundle (100 asserts) es el único que corre el bootstrapper de verdad: arranca
`FatCatInit`, comprueba que ningún módulo falló, que el shell publicó
`_G.FatCatHub`, que hay exactamente 7 pestañas y ninguna vacía, que un preset
llega al shell por su flag, y que `Core:Destroy()` deja el global en nil y no
se puede volver a pedir un módulo después.

`tools/fatchub/mock.lua` simula el DataModel: instancias, señales, tweens
(inmediatos), `task` (manual, con `flush()`), `HttpService` con JSON real,
archivos en memoria y `typeof`/`Color3` con los tipos de Roblox. Los asserts
comprueban que los valores llegan a los setters, que los callbacks disparan una
vez, el buscador, save/load/reset, cambio de pestaña y que `Destroy` desconecta
todo.

`tools/fatchub/layout.lua` mide el árbol construido (AnchorPoint, escala,
`UIListLayout`, `UIPadding`, `AutomaticSize`, cadenas de recorte y `ZIndex`) y
`tools/fatchub/render.py` lo dibuja a PNG con **letras reales**, en stdlib
puro. `tools/fatchub/audit.py` revisa el mismo volcado contra reglas de diseño
(texto cortado, contraste, blancos táctiles, ritmo de espaciado) y
`tools/fatchub/fixtures/` prueba cada regla con un menú roto a propósito.

Detalle completo en [`FATCAT-DESIGN.md`](FATCAT-DESIGN.md).

El harness del loader no usa red: simula `game:HttpGet`, `loadstring`, `getgenv`,
`print` y `warn`, y le pasa como respuesta una página HTML, un cuerpo truncado,
un archivo que no es la librería, una librería con error de sintaxis, un
`HttpGet` que lanza, y el caso bueno. Comprueba además que cae a la rama
siguiente y que `_G.FatCatHubBranch` manda.

Prueba que no se puede hacer acá: el menú en Roblox vivo. El VM es el Luau real,
pero la fuente, los textos y el render final los pone el cliente.

## El proyecto modular

El menú de este documento es la **ventana**. Encima vive `src/project/`: veinte
módulos que se cargan en un orden explícito y comparten un solo global
(`_G.FatCatProject`), un solo ciclo de vida y un solo Unload.

### Cómo se ensambla

```
src/project/*.lua + src/FatCatInit.lua + src/FatCatHub.lua
        └── tools/build_bundle.py ──► src/FatCatHub.bundle.lua
                                          └── el loader baja este archivo
```

Cada módulo va dentro de su propio `do ... end`, así que un `local Core` en uno
no colisiona con el del siguiente; lo único que escapa es el valor guardado en
la tabla `Modules`. `FatCatInit` recibe esa tabla y decide el orden:

| Etapa | Módulos | Si falla |
| --- | --- | --- |
| 1 | `FatCatSignal` | fatal |
| 2 | `FatCatCore` | fatal |
| 3 | `FatCatEnv`, `FatCatConfig`, `FatCatDesign`, `FatCatMaterials`, `FatCatMath` | fatal, salvo Math (aviso) |
| 4 | `FatCatHub` (el shell) | fatal |
| 5 | el resto, bajo demanda | la pestaña dice por qué |

Un fallo **no** deja una pantalla en blanco: `FatCatInit` dibuja una tarjeta con
la etapa y las dos primeras líneas del error, deja `getgenv().FatCatProjectUnload`
instalado, y el resto del menú sigue en pie. Una pestaña rota cuesta una
pestaña.

### Las siete pestañas

La barra reparte `(ancho - 12) / n` por pestaña. A 460 px y 7 pestañas son 64 px
cada una; el nombre más ancho del proyecto (`Settings`) mide 54 px a 13 px. Con
8 pestañas el hueco baja a 56 px y empieza a apretar: la segunda herramienta va
en una sección de la misma pestaña, no en una pestaña nueva.

| Pestaña | Contenido |
| --- | --- |
| Home | estado del ejecutor, capacidades, paleta, atajo, Unload |
| Create | creador visual de GUIs (documento → instancias) |
| Inspect | jerarquía, propiedades, tablas con ciclos |
| Scripts | decompiler del ejecutor + extractor de scripts |
| Exploit | hooks de VM reversibles + configuración de proyectiles |
| Network | remote spy (FireServer / OnClientEvent, ring de 200) |
| Settings | presets JSON, sesión, recarga, Unload |

### Presets

Un preset es el `Hub.Values` del shell, filtrado a texto/número/booleano y
escrito en `FatCatProject/presets/<nombre>.json`, con un `index.json` que
guarda el orden y el activo. Los valores se aplican por `Hub.Setters`, uno por
uno: un flag que ya no existe se omite en vez de abortar la carga.

### Unload

`getgenv().FatCatProjectUnload()` corre en este orden:

1. para los bucles que el proyecto posee;
2. destruye la ventana (el `ScreenGui` cuelga de `CoreGui`, así que se lleva
   las siete pestañas);
3. corre los teardowns de los módulos en orden inverso al de carga, cada uno en
   `pcall`;
4. suelta `_G.FatCatProject` **al final**, para que los teardowns del paso 3
   todavía puedan encontrarlo.

El paso 4 antes del 3 es el bug clásico de unload: el teardown lee un global
nil y el error se pierde.
