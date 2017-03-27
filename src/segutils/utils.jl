
module Utils
#all other misc segmentation utils

export relabel_data!, relabel_data
export centers_of_mass, filter_by_size!


function relabel_data!{T}( d::AbstractArray{T}, mapping )

  zT = zero(T)
  for i in eachindex(d)

    if d[i] == zT continue end

    v = d[i]
    d[i] = get( mapping, v, v );
  end

end


function relabel_data{T}( d::AbstractArray{T}, mapping )

  s = size(d)
  res = zeros(T, s)

  zT = zero(T)
  for i in eachindex(d)

    if d[i] == zT continue end

    d[i] = get( mapping, v, v );
  end

  res
end


function centers_of_mass{T}( d::AbstractArray{T} )

  coms = Dict{T,Vector}()
  sizes = Dict{T,Int}()

  sx,sy,sz = size(d)
  zT = zero(T)
  for k in 1:sz, j in 1:sy, i in 1:sx

    if d[i,j,k] == zT continue end
    segid = d[i,j,k]

    coms[segid]  = get( coms, segid, [0,0,0]) + [i,j,k]
    sizes[segid] = get( sizes, segid, 0) + 1
  end

  for k in keys(coms)
    coms[k] = round(Int, coms[k] / sizes[k])
  end

  coms
end


function filter_by_size!( d::AbstractArray, thresh::Integer )

  szs = segment_sizes(d)

  to_keep = Vector{eltype(keys(szs))}()

  for (segid,size) in szs
    if size > thresh push!(to_keep, segid) end
  end

  if length(to_keep) == 0 warn("no segments remaining after size threshold") end

  for i in eachindex(d)
    if !(d[i] in to_keep)
      d[i] = eltype(d)(0)
    end
  end

end


function segment_sizes{T}( d::AbstractArray{T} )

  sizes = Dict{T,Int}()
  zT = zero(T)

  for i in eachindex(d)

    if d[i] == zT continue end

    segid = d[i]
    sizes[segid] = get(sizes, segid, 0) + 1
  end

  sizes
end

end #module Utils