function bar_label_formatter(value::Number)
    return string(round(value; digits=3))
end

"""
    bar_default_fillto(tf, ys, offset)::(ys, offset)

Returns the default y-positions and offset positions for the given transform `tf`.

In order to customize this for your own transformation type, you can dispatch on
`tf`.

Returns a Tuple of new y positions and offset arrays.

## Arguments
- `tf`: `plot.transformation.transform_func[]`.
- `ys`: The y-values passed to `barplot`.
- `offset`: The `offset` parameter passed to `barplot`.
"""
function bar_default_fillto(tf, ys, offset, in_y_direction)
    return ys, offset
end

# `fillto` is related to `y-axis` transofrmation only, thus we expect `tf::Tuple`
function bar_default_fillto(tf::Tuple, ys, offset, in_y_direction)
    _logT = Union{typeof(log), typeof(log2), typeof(log10), Base.Fix1{typeof(log), <: Real}}
    if in_y_direction && tf[2] isa _logT || (!in_y_direction && tf[1] isa _logT)
        # x-scale log and !(in_y_direction) is equiavlent to y-scale log in_y_direction
        # use the minimal non-zero y divided by 2 as lower bound for log scale
        smart_fillto = minimum(y -> y<=0 ? oftype(y, Inf) : y, ys) / 2
        return clamp.(ys, smart_fillto, Inf), smart_fillto
    else
        return ys, offset
    end
end

"""
    barplot(x, y; kwargs...)

Plots a barplot; `y` defines the height. `x` and `y` should be 1 dimensional.
Bar width is determined by the attribute `width`, shrunk by `gap` in the following way:
`width -> width * (1 - gap)`.

## Attributes
$(ATTRIBUTES)
"""
@recipe(BarPlot, x, y) do scene
    Attributes(;
        fillto = automatic,
        offset = 0.0,
        color = theme(scene, :patchcolor),
        alpha = 1.0,
        colormap = theme(scene, :colormap),
        colorscale = identity,
        colorrange = automatic,
        lowclip = automatic,
        highclip = automatic,
        nan_color = :transparent,
        dodge = automatic,
        n_dodge = automatic,
        gap = 0.2,
        dodge_gap = 0.03,
        marker = Rect,
        stack = automatic,
        strokewidth = theme(scene, :patchstrokewidth),
        strokecolor = theme(scene, :patchstrokecolor),
        width = automatic,
        direction = :y,
        visible = theme(scene, :visible),
        inspectable = theme(scene, :inspectable),
        cycle = [:color => :patchcolor],

        bar_labels = nothing,
        flip_labels_at = Inf,
        label_rotation = 0π,
        label_color = theme(scene, :textcolor),
        color_over_background = automatic,
        color_over_bar = automatic,
        label_offset = 5,
        label_font = theme(scene, :font),
        label_size = theme(scene, :fontsize),
        label_formatter = bar_label_formatter,
        label_align = automatic,
        transparency = false
    )
end

conversion_trait(::Type{<: BarPlot}) = PointBased()

function bar_rectangle(x, y, width, fillto, in_y_direction)
    # y could be smaller than fillto...
    ymin = min(fillto, y)
    ymax = max(fillto, y)
    w = abs(width)
    rect = Rectf(x - (w / 2f0), ymin, w, ymax - ymin)
    return in_y_direction ? rect : flip(rect)
end

flip(r::Rect2) = Rect2(reverse(origin(r)), reverse(widths(r)))

function compute_x_and_width(x, width, gap, dodge, n_dodge, dodge_gap)
    width === automatic && (width = 1)
    width *= 1 - gap
    if dodge === automatic
        i_dodge = 1
    elseif eltype(dodge) <: Integer
        i_dodge = dodge
    else
        ArgumentError("The keyword argument `dodge` currently supports only `AbstractVector{<: Integer}`") |> throw
    end
    n_dodge === automatic && (n_dodge = maximum(i_dodge))
    dodge_width = scale_width(dodge_gap, n_dodge)
    shifts = shift_dodge.(i_dodge, dodge_width, dodge_gap)
    return x .+ width .* shifts, width * dodge_width
end

scale_width(dodge_gap, n_dodge) = (1 - (n_dodge - 1) * dodge_gap) / n_dodge

function shift_dodge(i, dodge_width, dodge_gap)
    (dodge_width - 1) / 2 + (i - 1) * (dodge_width + dodge_gap)
end

function stack_from_to_sorted(y)
    to = cumsum(y)
    from = [0.0; to[firstindex(to):end-1]]

    (from = from, to = to)
end

function stack_from_to(i_stack, y)
    # save current order
    order = 1:length(y)
    # sort by i_stack
    perm = sortperm(i_stack)
    # restore original order
    inv_perm = sortperm(order[perm])

    from, to = stack_from_to_sorted(view(y, perm))

    (from = view(from, inv_perm), to = view(to, inv_perm))
end

function stack_grouped_from_to(i_stack, y, grp)
    from = Array{Float64}(undef, length(y))
    to   = Array{Float64}(undef, length(y))

    groupby = StructArray((; grp...))
    grps = StructArrays.finduniquesorted(groupby)
    last_pos = map(grps) do (g, inds)
        g => any(y[inds] .> 0) || all(y[inds] .== 0)
    end |> Dict
    is_pos = map(y, groupby) do v, g
        last_pos[g] = iszero(v) ? last_pos[g] : v > 0
    end

    groupby = StructArray((; grp..., is_pos))
    grps = StructArrays.finduniquesorted(groupby)
    for (grp, inds) in grps
        fromto = stack_from_to(i_stack[inds], y[inds])
        from[inds] .= fromto.from
        to[inds] .= fromto.to
    end

    (from = from, to = to)
end

function calculate_bar_label_align(label_align, label_rotation::Real, in_y_direction::Bool, flip::Bool)
    if label_align == automatic
        return angle2align(-label_rotation - !flip * pi + in_y_direction * pi/2)
    else
        return to_align(label_align, "Failed to convert `label_align` $label_align.")
    end
end

function text_attributes(values, in_y_direction, flip_labels_at, color_over_background, color_over_bar,
                         label_offset, label_rotation, label_align)
    aligns = Vec2f[]
    offsets = Vec2f[]
    text_colors = RGBAf[]
    swap(x, y) = in_y_direction ? (x, y) : (y, x)
    geti(x::AbstractArray, i) = x[i]
    geti(x, i) = x
    function flip(k)
        if flip_labels_at isa Number
            return k > flip_labels_at || k < 0
        elseif flip_labels_at isa Tuple{<:Number, <: Number}
            return (k > flip_labels_at[2] || k < 0) && k > flip_labels_at[1]
        else
            error("flip_labels_at needs to be a tuple of two numbers (low, high), or a single number (high)")
        end
    end

    for (i, k) in enumerate(values)

        isflipped = flip(k)

        push!(aligns, calculate_bar_label_align(label_align, label_rotation, in_y_direction, isflipped))

        if isflipped
            # plot text inside bar
            push!(offsets, swap(0, -label_offset))
            push!(text_colors, geti(color_over_bar, i))
        else
            # plot text next to bar
            push!(offsets, swap(0, label_offset))
            push!(text_colors, geti(color_over_background, i))
        end
    end
    return aligns, offsets, text_colors
end

function barplot_labels(xpositions, ypositions, bar_labels, in_y_direction, flip_labels_at,
                        color_over_background, color_over_bar, label_formatter, label_offset, label_rotation,
                        label_align)
    if bar_labels isa Symbol && bar_labels in (:x, :y)
        bar_labels = map(xpositions, ypositions) do x, y
            if bar_labels === :x
                label_formatter.(x)
            else
                label_formatter.(y)
            end
        end
    end
    if bar_labels isa AbstractVector
        if length(bar_labels) == length(xpositions)
            attributes = text_attributes(ypositions, in_y_direction, flip_labels_at, color_over_background,
                                         color_over_bar, label_offset, label_rotation, label_align)
            label_pos = map(xpositions, ypositions, bar_labels) do x, y, l
                return (string(l), in_y_direction ? Point2f(x, y) : Point2f(y, x))
            end
            return (label_pos, attributes...)
        else
            error("Labels and bars need to have same length. Found: $(length(xpositions)) bars with these labels: $(bar_labels)")
        end
    else
        error("Unsupported label type: $(typeof(bar_labels)). Use: :x, :y, or a vector of values that can be converted to strings.")
    end
end

function Makie.plot!(p::BarPlot)

    labels = Observable(Tuple{Union{String,LaTeXStrings.LaTeXString}, Point2f}[])
    label_aligns = Observable(Vec2f[])
    label_offsets = Observable(Vec2f[])
    label_colors = Observable(RGBAf[])
    function calculate_bars(xy, fillto, offset, transformation, width, dodge, n_dodge, gap, dodge_gap, stack,
                            dir, bar_labels, flip_labels_at, label_color, color_over_background,
                            color_over_bar, label_formatter, label_offset, label_rotation, label_align)

        in_y_direction = get((y=true, x=false), dir) do
            error("Invalid direction $dir. Options are :x and :y.")
        end

        x = first.(xy)
        y = last.(xy)

        # by default, `width` is `minimum(diff(sort(unique(x)))`
        if width === automatic
            x_unique = unique(filter(isfinite, x))
            x_diffs = diff(sort(x_unique))
            width = isempty(x_diffs) ? 1.0 : minimum(x_diffs)
        end

        # compute width of bars and x̂ (horizontal position after dodging)
        x̂, barwidth = compute_x_and_width(x, width, gap, dodge, n_dodge, dodge_gap)

        # --------------------------------
        # ----------- Stacking -----------
        # --------------------------------

        if stack === automatic
            if fillto === automatic
                y, fillto = bar_default_fillto(transformation, y, offset, in_y_direction)
            end
        elseif eltype(stack) <: Integer
            fillto === automatic || @warn "Ignore keyword fillto when keyword stack is provided"
            if !iszero(offset)
                @warn "Ignore keyword offset when keyword stack is provided"
                offset = 0.0
            end
            i_stack = stack

            from, to = stack_grouped_from_to(i_stack, y, (x = x̂,))
            y, fillto = to, from
        else
            ArgumentError("The keyword argument `stack` currently supports only `AbstractVector{<: Integer}`") |> throw
        end

        # --------------------------------
        # ----------- Labels -------------
        # --------------------------------

        if !isnothing(bar_labels)
            oback = color_over_background === automatic ? label_color : color_over_background
            obar = color_over_bar === automatic ? label_color : color_over_bar
            label_args = barplot_labels(x̂, y, bar_labels, in_y_direction,
                                        flip_labels_at, to_color(oback), to_color(obar),
                                        label_formatter, label_offset, label_rotation, label_align)
            labels[], label_aligns[], label_offsets[], label_colors[] = label_args
        end

        return bar_rectangle.(x̂, y .+ offset, barwidth, fillto, in_y_direction)
    end

    bars = lift(calculate_bars, p, p[1], p.fillto, p.offset, p.transformation.transform_func, p.width, p.dodge, p.n_dodge, p.gap,
                p.dodge_gap, p.stack, p.direction, p.bar_labels, p.flip_labels_at,
                p.label_color, p.color_over_background, p.color_over_bar, p.label_formatter, p.label_offset, p.label_rotation, p.label_align; priority = 1)
    poly!(
        p, bars, color = p.color, colormap = p.colormap, colorscale = p.colorscale, colorrange = p.colorrange,
        strokewidth = p.strokewidth, strokecolor = p.strokecolor, visible = p.visible,
        inspectable = p.inspectable, transparency = p.transparency,
        highclip = p.highclip, lowclip = p.lowclip, nan_color = p.nan_color, alpha = p.alpha,
    )

    if !isnothing(p.bar_labels[])
        text!(p, labels; align=label_aligns, offset=label_offsets, color=label_colors, font=p.label_font, fontsize=p.label_size, rotation=p.label_rotation)
    end
end
