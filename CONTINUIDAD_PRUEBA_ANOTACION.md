# Santa Padel Club — continuidad de la prueba de anotación

Actualizado: 2026-10-28

## Límites acordados

- Trabajar solo con Santa Padel Club en `/home/martin-godoy/Descargas/Padel`.
- No tocar `once-verduleria`.
- No pedir ni compartir claves, tokens o contraseñas.
- No crear ni modificar partidos/datos en producción, no ejecutar SQL de escritura y no publicar cambios.
- Guiar con instrucciones breves, una pantalla/acción por vez. El usuario está cuidando el límite de uso: evitar preguntas repetidas y pruebas punto por punto más largas de lo necesario.

## Copia local de prueba

- Archivo abierto: `work/prueba-anotacion.html`.
- Es una simulación sin conexión a Supabase, con jugadores/partido ficticios en memoria; al recargar se reinicia.
- No editar `index.html` ni desplegar nada como parte de esta prueba.
- La simulación ordenaba mal los IDs `e1`, `e10`, `e2` como texto una vez que había más de nueve eventos. Se corrigió la ordenación numérica solo en `work/prueba-anotacion.html`; esa anomalía no prueba un defecto en la app original.
- El usuario pidió separar juegos y puntos visualmente: juegos con guion (p. ej. `3–3`) y puntos con barra (p. ej. `0/0`). Se cambió el formateador local. La vista siguió mostrando guion en algún marcador después del cambio, así que falta confirmar si la barra se ve en todos los casos; no recargar sin avisar porque se pierde el estado ficticio actual.

## Casos ya comprobados en la simulación

- Preparación: pareja que saca primero y primer sacador de cada pareja.
- Los tres botones suman a la pareja seleccionada: `Punto`, `Winner` y `Error rival`.
- Winner permitió elegir a Dani; Error rival permitió elegir a Cata. El marcador es por pareja y no muestra estadísticas individuales en esa pantalla.
- Tanteo normal: `15`, `30`, `40`; empate `40–40` mostró Punto de Oro y el punto siguiente cerró el juego y reinició el tanteo.
- Deshacer quitó un punto y restauró `0–0` sin cambiar los juegos.
- Se implementó localmente el límite solicitado para Deshacer: un punto que cierra un juego sigue siendo corregible hasta que se anota el primer punto del juego siguiente; desde entonces, Deshacer solo vuelve hasta `0/0` del juego actual y no cruza al anterior. El límite se guarda en el JSONB existente `estado_marcador`; no requiere SQL.
- Rotación de saque verificada: Ana → Cata → Beto → Dani, y vuelta a Ana.
- Con más de diez eventos, tras corregir el orden de la simulación, los puntos siguieron en secuencia y el segundo juego cerró correctamente.
- La lógica nueva de límite de Deshacer pasó una comprobación local con partidos ficticios y los scripts de las tres copias HTML pasaron verificación de sintaxis.

## Estado exacto al pausar

En la última captura, la simulación estaba en un set, juegos `3–3`, **tie-break a 7**, puntos `0–0`. El sacador resaltado era **Beto**. A/B aparece seleccionado para anotar, pero todavía no se ha anotado ningún punto del tie-break.

Los cambios de Deshacer y el formato de puntos con `/` están guardados localmente en `index.html`, `notificaciones-push/publicar/index.html` y la simulación. No están publicados. La pestaña que ya estaba abierta conserva el JavaScript anterior hasta recargar; recargar reinicia los datos ficticios de la simulación.

Si se retoma la prueba, el siguiente caso es anotar un punto de tie-break y comprobar que el tanteo use números (`1/0` o el formato que finalmente se acuerde), luego verificar la rotación de saque del tie-break. No hace falta volver a repetir los casos ya comprobados.

## Instrucción para el próximo chat

**No reiniciar ni volver a simular los casos ya completados.** Tomar este registro como evidencia de las pruebas hechas y continuar directamente con el tie-break desde el estado indicado arriba. El estado dentro del navegador es solo temporal: si el otro chat no puede ver la pantalla actual o la página se recargó, explicar esa limitación y consultar primero al usuario antes de rehacer la prueba completa. No volver a pedirle los mismos resultados.

El usuario quiere conservar uso: evitar el interrogatorio de un clic por mensaje si se puede agrupar una instrucción corta y clara, sin perder la guía paso a paso que pidió.

## Producción y servicios

- La app real usa el campo existente `estado_marcador`; en la revisión previa no parecía requerir SQL.
- La última lectura previa encontró `public.partidos_fixture` sin partidos, por lo que no se hizo prueba real. Ese dato puede haber cambiado; verificar en lectura antes de apoyarse en él.
- GitHub/Supabase se revisaron en modo lectura previamente. No se hizo ninguna escritura ni publicación.
- Esta carpeta local no es un checkout Git válido en esta sesión (`git rev-parse` falló), así que esta nota queda en la carpeta local; no está subida al repositorio de GitHub.

