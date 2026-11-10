# Angel Hub — menú vacío, listo para llenar

El shell del menú que subiste (`cule.txt`), sin una sola línea de Illegal Soccer.
El GUI es el mismo de arriba a abajo — ventana arrastrable, pestañas con
indicador animado, tarjetas con ripple, toggles, sliders, ciclos, buscador,
toasts, config, minimizar, resize — y todo lo que era del juego se fue.
Las pestañas están vacías a propósito: **el menú no registra ningún módulo**.

```
src/AngelHub.lua          el menú completo (shell + componentes + API)
src/AngelHub.loader.lua   loader de una línea
tools/angelhub/           harness: mock de Roblox, asserts, render PNG
docs/ANGEL-HUB.md         esto
```

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/main/src/AngelHub.loader.lua"))()
```

El loader baja `src/AngelHub.lua`, lo compila (con el número de línea exacto si
hay error de sintaxis), lo ejecuta y devuelve `_G.AngelHub`. Para cerrarlo:

```lua
getgenv().AngelHubUnload()
```

También funciona pegado directo en el executor, sin loader.

## Llenar el menú

```lua
local Hub = _G.AngelHub
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
Hub:Save(true)     -- AngelHub/config.json  (notifica el resultado)
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

Mejoras visuales:

- **Contraste**: fondo `26→12`, tarjetas `38`, sección `17`, contorno `104`.
  El original se leía como una losa negra.
- **Hover honesto**: la tarjeta aclara y el borde se enciende, en vez del salto
  de transparencia `0.35 ↔ 0.65`.
- **Sombra real**: tres capas desplazadas detrás de la ventana; también se mueve
  al arrastrar.
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

## Verificación

```bash
bash tools/luau/setup.sh          # toolchain (una vez)
bash tools/test_angelhub.sh       # 63 asserts sobre Roblox simulado
bash tools/render_angelhub.sh     # build/AngelHub.png
```

`tools/angelhub/mock.lua` simula el DataModel: instancias, señales, tweens
(inmediatos), `task` (manual, con `flush()`), `HttpService` con JSON real,
archivos en memoria y `typeof`/`Color3` con los tipos de Roblox. Los asserts
comprueban que los valores llegan a los setters, que los callbacks disparan una
vez, el buscador, save/load/reset, cambio de pestaña y que `Destroy` desconecta
todo.

`tools/angelhub/layout.lua` mide el árbol construido (AnchorPoint, escala,
`UIListLayout`, `UIPadding`, `AutomaticSize`) y `tools/angelhub/render.py` lo
dibuja a PNG en stdlib puro. El texto sale como barra proporcional: el render
prueba geometría, apilado, color y recorte, **no** las letras.

Prueba que no se puede hacer acá: el menú en Roblox vivo. El VM es el Luau real,
pero la fuente, los textos y el render final los pone el cliente.
