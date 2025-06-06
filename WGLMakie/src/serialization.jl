using ShaderAbstractions: InstancedProgram, Program
using Makie: Key, plotkey
using Colors: N0f8

function lift_convert(key, value, ::Attributes)
    convert(value) = wgl_convert(value, Key{key}())
    if value isa Observable
        val = lift(convert, value)
    else
        val = convert(value)
    end
    if key === :colormap && val[] isa AbstractArray
        return ShaderAbstractions.Sampler(val)
    else
        return val
    end
end


function lift_convert(key, value, plot)
    convert(value) = wgl_convert(value, Key{key}(), Key{plotkey(plot)}())
    if value isa Observable
        val = lift(convert, plot, value)
    else
        val = convert(value)
    end
    if key === :colormap && val[] isa AbstractArray
        return ShaderAbstractions.Sampler(val)
    else
        return val
    end
end

_pairs(any) = Base.pairs(any)
function _pairs(mesh::GeometryBasics.Mesh)
    return (kv for kv in GeometryBasics.attributes(mesh))
end

# Don't overload faces to not invalidate
_faces(x::VertexArray) = _faces(getfield(x, :data))
function _faces(x)
    return GeometryBasics.faces(x)
end

tlength(T) = length(T)
tlength(::Type{<:Real}) = 1

serialize_three(val::Number) = val
serialize_three(val::Vec2f) = convert(Vector{Float32}, val)
serialize_three(val::Vec3f) = convert(Vector{Float32}, val)
serialize_three(val::Vec4f) = convert(Vector{Float32}, val)
serialize_three(val::Quaternion) = convert(Vector{Float32}, collect(val.data))
serialize_three(val::RGB) = Float32[red(val), green(val), blue(val)]
serialize_three(val::RGBA) = Float32[red(val), green(val), blue(val), alpha(val)]
serialize_three(val::Mat4f) = collect(vec(val))
serialize_three(val::Mat3) = collect(vec(val))

function serialize_three(array::AbstractArray)
    return serialize_three(flatten_buffer(array))
end

function serialize_three(array::Buffer)
    return serialize_three(flatten_buffer(array))
end

serialize_three(array::AbstractArray{UInt8}) = vec(array)
serialize_three(array::AbstractArray{Int32}) = vec(array)
serialize_three(array::AbstractArray{UInt32}) = vec(array)
serialize_three(array::AbstractArray{Float32}) = vec(array)
serialize_three(array::AbstractArray{Float16}) = vec(array)
serialize_three(array::AbstractArray{Float64}) = vec(array)

function serialize_three(p::Makie.AbstractPattern)
    return serialize_three(Makie.to_image(p))
end

three_format(::Type{<:Real}) = "RedFormat"
three_format(::Type{<:RGB}) = "RGBFormat"
three_format(::Type{<:RGBA}) = "RGBAFormat"

three_type(::Type{Float16}) = "FloatType"
three_type(::Type{Float32}) = "FloatType"
three_type(::Type{N0f8}) = "UnsignedByteType"

function three_filter(sym::Symbol)
    sym === :linear && return "LinearFilter"
    sym === :nearest && return "NearestFilter"
    error("Unknown filter mode '$sym'")
end

function three_repeat(s::Symbol)
    s === :clamp_to_edge && return "ClampToEdgeWrapping"
    s === :mirrored_repeat && return "MirroredRepeatWrapping"
    s === :repeat && return "RepeatWrapping"
    error("Unknown repeat mode '$s'")
end

function serialize_three(color::Sampler{T,N}) where {T,N}
    tex = Dict(:type => "Sampler", :data => serialize_three(color.data),
               :size => Int32[size(color.data)...], :three_format => three_format(T),
               :three_type => three_type(eltype(T)),
               :minFilter => three_filter(color.minfilter),
               :magFilter => three_filter(color.magfilter),
               :wrapS => three_repeat(color.repeat[1]), :anisotropy => color.anisotropic)
    if N > 1
        tex[:wrapT] = three_repeat(color.repeat[2])
    end
    if N > 2
        tex[:wrapR] = three_repeat(color.repeat[3])
    end
    return tex
end

function serialize_uniforms(dict::Dict)
    result = Dict{Symbol,Any}()
    for (k, v) in dict
        # we don't send observables and instead use
        # uniform_updater(dict)
        result[k] = serialize_three(to_value(v))
    end
    return result
end



"""
    flatten_buffer(array::AbstractArray)

Flattens `array` array to be a 1D Vector of Float32 / UInt8.
If presented with AbstractArray{<: Colorant/Tuple/SVector}, it will flatten those
to their element type.
"""
function flatten_buffer(array::AbstractArray{<: Number})
    return array
end
function flatten_buffer(array::AbstractArray{<:AbstractFloat})
    return convert(Array{Float32}, array)
end
function flatten_buffer(array::Buffer)
    return flatten_buffer(getfield(array, :data))
end

function flatten_buffer(array::AbstractArray{T}) where {T<:N0f8}
    return reinterpret(UInt8, array)
end

function flatten_buffer(array::AbstractArray{T}) where {T}
    return flatten_buffer(collect(reinterpret(eltype(T), array)))
end

lasset(paths...) = read(joinpath(@__DIR__, "..", "assets", paths...), String)

isscalar(x::StaticVector) = true
isscalar(x::Mat) = true
isscalar(x::AbstractArray) = false
isscalar(x::Billboard) = isscalar(x.rotation)
isscalar(x::Observable) = isscalar(x[])
isscalar(x) = true

function ShaderAbstractions.type_string(::ShaderAbstractions.AbstractContext,
                                        ::Type{<:Makie.Quaternion})
    return "vec4"
end

function ShaderAbstractions.convert_uniform(::ShaderAbstractions.AbstractContext,
                                            t::Quaternion)
    return convert(Quaternion, t)
end



function wgl_convert(value, key1, key2...)
    val = Makie.convert_attribute(value, key1, key2...)
    return if val isa AbstractArray{<:Float64}
        return Makie.el32convert(val)
    else
        return val
    end
end

function wgl_convert(value::AbstractMatrix, ::key"colormap", key2...)
    return ShaderAbstractions.Sampler(value)
end

function serialize_buffer_attribute(buffer::AbstractVector{T}) where {T}
    return Dict(:flat => serialize_three(buffer), :type_length => tlength(T))
end

function serialize_named_buffer(buffer)
    return Dict(map(_pairs(buffer)) do (name, buff)
                    return name => serialize_buffer_attribute(buff)
                end)
end

function register_geometry_updates(update_buffer::Observable, named_buffers)
    for (name, buffer) in _pairs(named_buffers)
        if buffer isa Buffer
            on(ShaderAbstractions.updater(buffer).update) do (f, args)
                # update to replace the whole buffer!
                if f === ShaderAbstractions.update!
                    new_array = args[1]
                    flat = flatten_buffer(new_array)
                    update_buffer[] = [name, serialize_three(flat), length(new_array)]
                end
                return
            end
        end
    end
    return update_buffer
end

function register_geometry_updates(update_buffer::Observable, program::Program)
    return register_geometry_updates(update_buffer, program.vertexarray)
end

function register_geometry_updates(update_buffer::Observable, program::InstancedProgram)
    return register_geometry_updates(update_buffer, program.per_instance)
end

function uniform_updater(uniforms::Dict)
    updater = Observable(Any[:none, []])
    for (name, value) in uniforms
        if value isa Sampler
            on(ShaderAbstractions.updater(value).update) do (f, args)
                if f === ShaderAbstractions.update!
                    updater[] = [name, [Int32[size(value.data)...], serialize_three(args[1])]]
                end
                return
            end
        else
            value isa Observable || continue
            on(value) do value
                updater[] = [name, serialize_three(value)]
                return
            end
        end
    end
    return updater
end

function serialize_three(ip::InstancedProgram)
    program = serialize_three(ip.program)
    program[:instance_attributes] = serialize_named_buffer(ip.per_instance)
    register_geometry_updates(program[:attribute_updater], ip)
    return program
end

reinterpret_faces(faces::AbstractVector) = collect(reinterpret(UInt32, decompose(GLTriangleFace, faces)))

function reinterpret_faces(faces::Buffer)
    result = Observable(reinterpret_faces(ShaderAbstractions.data(faces)))
    on(ShaderAbstractions.updater(faces).update) do (f, args)
        if f === ShaderAbstractions.update!
            result[] = reinterpret_faces(args[1])
        end
    end
    return result
end


function serialize_three(program::Program)
    facies = reinterpret_faces(_faces(program.vertexarray))
    indices = convert(Observable, facies)
    uniforms = serialize_uniforms(program.uniforms)
    attribute_updater = Observable(["", [], 0])
    register_geometry_updates(attribute_updater, program)
    # TODO, make this configurable in ShaderAbstractions
    update_shader(x) = replace(x, "#version 300 es" => "")
    return Dict(:vertexarrays => serialize_named_buffer(program.vertexarray),
                :faces => indices, :uniforms => uniforms,
                :vertex_source => update_shader(program.vertex_source),
                :fragment_source => update_shader(program.fragment_source),
                :uniform_updater => uniform_updater(program.uniforms),
                :attribute_updater => attribute_updater)
end

function serialize_scene(scene::Scene)

    hexcolor(c) = "#" * hex(Colors.color(to_color(c)))
    pixel_area = lift(area -> Int32[minimum(area)..., widths(area)...], pixelarea(scene))

    cam_controls = cameracontrols(scene)

    cam3d_state = if cam_controls isa Camera3D
        fields = (:lookat, :upvector, :eyeposition, :fov, :near, :far)
        dict = Dict((f => serialize_three(getfield(cam_controls, f)[]) for f in fields))
        dict[:resolution] = lift(res -> Int32[res...], scene.camera.resolution)
        dict
    else
        nothing
    end

    children = map(child-> serialize_scene(child), scene.children)

    serialized = Dict(:pixelarea => pixel_area,
                      :backgroundcolor => lift(hexcolor, scene.backgroundcolor),
                      :clearscene => scene.clear,
                      :camera => serialize_camera(scene),
                      :plots => serialize_plots(scene, scene.plots),
                      :cam3d_state => cam3d_state,
                      :visible => scene.visible,
                      :uuid => js_uuid(scene),
                      :children => children)
    return serialized
end

function serialize_plots(scene::Scene, plots::Vector{T}, result=[]) where {T<:AbstractPlot}
    for plot in plots
        # if no plots inserted, this truely is an atomic
        if isempty(plot.plots)
            plot_data = serialize_three(scene, plot)
            plot_data[:uuid] = js_uuid(plot)
            push!(result, plot_data)
        else
            serialize_plots(scene, plot.plots, result)
        end
    end
    return result
end

function serialize_three(scene::Scene, plot::AbstractPlot)
    program = create_shader(scene, plot)
    mesh = serialize_three(program)
    mesh[:name] = string(Makie.plotkey(plot)) * "-" * string(objectid(plot))
    mesh[:visible] = plot.visible
    mesh[:uuid] = js_uuid(plot)
    mesh[:transparency] = plot.transparency
    mesh[:overdraw] = plot.overdraw

    uniforms = mesh[:uniforms]
    updater = mesh[:uniform_updater]

    pointlight = Makie.get_point_light(scene)
    if !isnothing(pointlight)
        uniforms[:lightposition] = serialize_three(pointlight.position[])
        on(pointlight.position) do value
            updater[] = [:lightposition, serialize_three(value)]
            return
        end
    end

    ambientlight = Makie.get_ambient_light(scene)
    if !isnothing(ambientlight)
        uniforms[:ambient] = serialize_three(ambientlight.color[])
        on(ambientlight.color) do value
            updater[] = [:ambient, serialize_three(value)]
            return
        end
    end

    if haskey(plot, :markerspace)
        mesh[:markerspace] = plot.markerspace
    end
    mesh[:space] = plot.space

    key = haskey(plot, :markerspace) ? (:markerspace) : (:space)
    mesh[:cam_space] = to_value(get(plot, key, :data))

    return mesh
end

function serialize_camera(scene::Scene)
    cam = scene.camera
    return lift(scene, cam.view, cam.projection, cam.resolution) do view, proj, res
        # eyeposition updates with viewmatrix, since an eyepos change will trigger
        # a view matrix change!
        ep = cam.eyeposition[]
        return [vec(collect(view)), vec(collect(proj)), Int32[res...], Float32[ep...]]
    end
end
