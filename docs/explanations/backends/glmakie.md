# GLMakie

[GLMakie](https://github.com/MakieOrg/Makie.jl/tree/master/GLMakie) is the native, desktop-based backend, and is the most feature-complete.
It requires an OpenGL enabled graphics card with OpenGL version 3.3 or higher.

## Activation and screen config

Activate the backend by calling `GLMakie.activate!()`:
```julia:docs
# hideall
using GLMakie, Markdown
println("~~~")
println(Markdown.html(@doc GLMakie.activate!))
println("~~~")
```
\textoutput{docs}

#### Multiple Windows

GLMakie has experimental support for displaying multiple independent figures (or scenes). To open a new window, use `display(GLMakie.Screen(), figure_or_scene)`.


## Forcing Dedicated GPU Use In Linux

Normally the dedicated GPU is used for rendering.
If instead an integrated GPU is used, one can tell Julia to use the dedicated GPU while launching julia as `$ sudo DRI_PRIME=1 julia` in the bash terminal.
To have it permanently used, add the line `export DRI_PRIME=1` in  your `.bashrc` or `.zshrc` file.

## Troubleshooting OpenGL

If you get any error loading GLMakie, it likely means you don't have an OpenGL capable graphics card, or you don't have an OpenGL 3.3 capable driver installed.
Note that most GPUs, even 8 year old integrated ones, support OpenGL 3.3.

On Linux, you can find out your OpenGL version with:
`glxinfo | grep "OpenGL version"`

If you're using an AMD or Intel gpu on linux, you may run into [GLFW#198](https://github.com/JuliaGL/GLFW.jl/issues/198).

If you're on a headless server, you still need to install x-server and
proper graphics drivers.

You can find a demo on how to set that up in this [nextjournal article](https://nextjournal.com/sdanisch/GLMakie-nogpu).

GLMakie's CI has no GPU, so you can also look at [.github/workflows/glmakie.yaml](https://github.com/MakieOrg/Makie.jl/blob/master/.github/workflows/glmakie.yaml) for a working setup.

If none of these work for you, take a look at the other [backends](/documentation/backends/), which all work without a GPU.

If you get an error pointing to [GLFW.jl](https://github.com/JuliaGL/GLFW.jl), please look into the existing [GLFW issues](https://github.com/JuliaGL/GLFW.jl/issues), and also google for those errors. This is then very likely something that needs fixing in the  [glfw c library](https://github.com/glfw/glfw) or in the GPU drivers.


## WSL setup or X-forwarding

From: [Microsoft/WSL/issues/2855](https://github.com/Microsoft/WSL/issues/2855#issuecomment-358861903)

WSL runs OpenGL alright, but it is not a supported scenario.
From a clean Ubuntu install from the store do:

```
sudo apt install ubuntu-desktop mesa-utils
export DISPLAY=localhost:0
glxgears
```

On the Windows side:

1) install [VcXsrv](https://sourceforge.net/projects/vcxsrv/)
2) choose multiple windows -> display 0 -> start no client -> disable native opengl

Troubleshooting:

1.)  install: `sudo apt-get install -y xorg-dev mesa-utils xvfb libgl1 freeglut3-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxext-dev`

2.) WSL has some problems with passing through localhost, so one may need to use: `export DISPLAY=192.168.178.31:0`, with the local ip of the pcs network adapter, which runs VcXsrv

3.) One may need `mv /opt/julia-1.5.2/lib/julia/libstdc++.so.6 /opt/julia-1.5.2/lib/julia/libcpp.backup`, another form of [GLFW#198](https://github.com/JuliaGL/GLFW.jl/issues/198)

## GLMakie does not show Figure or crashes on full screen mode on macOS

MacOS gives a warning if a graphical user interface (GUI) is not started from an AppBundle and this exception can crash the Julia process that initiated the GUI. 
This warning only occurs if macOS Settings->Desktop & Dock->Menu Bar->Automatically hide and show the menu bar is not set to Never.
Therefore make sure this setting is set to `Never` to enable the use of GLMakie on macOS.
