topoint(x::AbstractVector{Point{N,Float32}}) where {N} = x

# GRRR STUPID SubArray, with eltype different from getindex(x, 1)
topoint(x::SubArray) = topoint([el for el in x])

function topoint(x::AbstractArray{<:Point{N,T}}) where {T,N}
    return topoint(Point{N,Float32}.(x))
end

function topoint(x::AbstractArray{<:Tuple{P,P}}) where {P<:Point}
    return topoint(reinterpret(P, x))
end

function create_shader(scene::Scene, plot::Union{Lines,LineSegments})
    # Potentially per instance attributes
    positions = lift(plot[1], transform_func_obs(plot), plot.space) do points, trans, space
        points = apply_transform(trans, topoint(points), space)
        if plot isa LineSegments
            return points
        else
            # Repeat every second point to connect the lines !
            return topoint(TupleView{2, 1}(points))
        end
        trans
    end

    startr = lift(p -> 1:2:(length(p) - 1), positions)
    endr = lift(p -> 2:2:length(p), positions)

    p_start_end = lift(positions) do positions
        return (positions[startr[]], positions[endr[]])
    end

    per_instance = Dict{Symbol,Any}(:segment_start => Buffer(lift(first, p_start_end)),
                                    :segment_end => Buffer(lift(last, p_start_end)))
    uniforms = Dict{Symbol,Any}()

    linewidth = converted_attribute(plot, :linewidth)
    cmap = plot.calculated_colors[]

    color = cmap isa Makie.ColorMapping ? cmap.color_scaled : plot.calculated_colors

    for (k, attribute) in [:linewidth => linewidth, :color => color]
        attribute = lift(attribute) do x
            plot isa LineSegments && return x
            # Repeat every second point to connect the lines!
            return isscalar(x) ? x : reinterpret(eltype(x), TupleView{2, 1}(x))
        end
        if isscalar(attribute)
            uniforms[k] = attribute
            uniforms[Symbol("$(k)_start")] = attribute
            uniforms[Symbol("$(k)_end")] = attribute
        else
            if attribute[] isa AbstractVector{<:Number} && k == :color
                @assert cmap isa Makie.ColorMapping
                attribute = lift(Makie.numbers_to_colors, attribute, cmap.colormap, identity,
                                 cmap.colorrange_scaled, cmap.lowclip,
                                 cmap.highclip,
                                 cmap.nan_color)
            end
            per_instance[Symbol("$(k)_start")] = Buffer(lift(x -> x[startr[]], attribute))
            per_instance[Symbol("$(k)_end")] = Buffer(lift(x -> x[endr[]], attribute))
        end
    end

    uniforms[:resolution] = to_value(scene.camera.resolution) # updates in JS

    uniforms[:model] = plot.model
    uniforms[:depth_shift] = get(plot, :depth_shift, Observable(0f0))
    positions = meta(Point2f[(0, -1), (0, 1), (1, -1), (1, 1)],
                     uv=Vec2f[(0, 0), (0, 0), (0, 0), (0, 0)])
    instance = GeometryBasics.Mesh(positions, GLTriangleFace[(1, 2, 3), (2, 4, 3)])

    # id + picking gets filled in JS, needs to be here to emit the correct shader uniforms
    uniforms[:picking] = false
    uniforms[:object_id] = UInt32(0)

    return InstancedProgram(WebGL(), lasset("line_segments.vert"),
                            lasset("line_segments.frag"), instance,
                            VertexArray(; per_instance...), uniforms)
end
