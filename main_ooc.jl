#!/usr/bin/env julia

#=
   Out of Core (OOC) Processing

   Hope to clean this up a bit more soon...but we'll see
=#

module main_ooc


unshift!(LOAD_PATH,".") #temporary


import io_u    # I/O Utils
import pinky_u # Pinky-Specific Utils
import seg_u   # Segmentation Utils
import chunk_u # Chunking Utils
import mfot    # Median-Over-Threshold Filter
import vol_u   # Data Volume Utils
import utils   # General Utils
import omni_u  # MST Utils

using BigArrays.H5sBigArrays

#------------------------------------------
# Command-line arguments

config_filename = ARGS[1]
#------------------------------------------

#lines using these should be marked with
#param
include("parameters.jl")
include(config_filename)


function main( segmentation_fname, output_prefix )

  seg, sem_output, mst_mapping = init_datasets( segmentation_fname )


  seg_origin_offset  = seg_start - 1;#param
  seg_bounds  = chunk_u.bounds( seg )#param
  sem_bounds  = chunk_u.bounds( sem_output, seg_origin_offset )

  valid_sem_bounds = chunk_u.intersect_bounds( sem_bounds, seg_bounds, seg_origin_offset )
  valid_seg_bounds = chunk_u.intersect_bounds( seg_bounds, sem_bounds, -seg_origin_offset )

  scan_bounds = scan_start_coord => scan_end_coord;
  #println("seg_bounds: $seg_bounds")
  #println("sem_bounds: $sem_bounds")
  #println("seg_origin_offset: $seg_origin_offset")
  #println("scan_bounds: $scan_bounds")
  #println("valid_seg_bounds: $valid_seg_bounds")
  @assert vol_u.in_bounds( scan_bounds, valid_seg_bounds )

  scan_vol_shape = chunk_u.vol_shape( scan_bounds ) #param

  scan_rel_offset = scan_start_coord - 1; #param
  #param
  scan_chunk_bounds = chunk_u.chunk_bounds( scan_vol_shape, scan_chunk_shape, scan_rel_offset )


  processed_voxels = Set{Tuple{Int,Int,Int}}();
  sizehint!(processed_voxels, set_size_hint) #param

  edges = Array{Tuple{Int,Int},1}();
  locations = Array{Tuple{Int,Int,Int},1}();
  voxels = Vector{Vector{Tuple{Int,Int,Int}}}();

  psd_w = chunk_u.init_inspection_window( w_radius, sem_dtype ) #param
  seg_w = chunk_u.init_inspection_window( w_radius, seg_dtype ) #param


  num_scan_chunks = length(scan_chunk_bounds)
  curr_chunk = 1
  for scan_bounds in scan_chunk_bounds

    println("Scan Chunk #$(curr_chunk) of $(num_scan_chunks): $(scan_bounds) ")

    #want the inspection block to represent all valid mfot values
    # in the original volume which can be reached by an inspection window
    # within the scan chunk. Need to increase the window radius to acct
    # for the median filtering operation
    println("Fetching Inspection Blocks...")
    @time ins_block, block_offset = chunk_u.fetch_inspection_block(
                                                      sem_output, scan_bounds,
                                                      seg_origin_offset,
                                                      w_radius + mfot_radius,
                                                      valid_sem_bounds ) #param
    @time seg_block, segb_offset  = chunk_u.fetch_inspection_block(
                                                      seg,        scan_bounds,
                                                      [0,0,0],
                                                      w_radius + mfot_radius,
                                                      valid_seg_bounds ) #param
    println("Thresholding segmentation block")
    @time vol_u.relabel_data!(seg_block, mst_mapping)


    println("Making semantic assignment...")
    @time semmap, _ = utils.make_semantic_assignment( seg_block, ins_block, [2,3] )


    psd_ins_block = ins_block[:,:,:,vol_map["PSD"]];


    println("Block median filter...")
    #param
    @time psd_ins_block = mfot.median_filter_over_threshold( psd_ins_block, mfot_radius, cc_thresh )


    scan_chunk = chunk_u.fetch_chunk( psd_ins_block, scan_bounds, seg_origin_offset-block_offset )
    scan_offset = scan_bounds.first - 1 + seg_origin_offset;

    # println("block offset: $(block_offset)")
    # println("scan_offset: $(scan_offset)")
    # println("scan_origin_offset: $(scan_origin_offset)")
    # println("ins block size: $(size(psd_ins_block))")
    # println("scan chunk size: $(size(psd_p))")


    # we've extracted everything we need from these
    ins_block = nothing
    gc()


    process_scan_chunk!( scan_chunk, psd_ins_block, seg_block, semmap,
                         edges, locations, voxels, processed_voxels,

                         psd_w, seg_w,

                         scan_offset, block_offset, valid_sem_bounds
                         )

    println("") #adding space to output
    curr_chunk += 1

  end

  println("Saving edge information")
  io_u.save_edge_file( edges, locations, 1:length(locations),
                       "$(output_prefix)_edges.csv" )
  io_u.save_voxel_file( voxels, 1:length(locations),
                       "$(output_prefix)_voxels.csv")

end


function init_datasets( segmentation_filename )

  println("Reading segmentation file...")
  @time seg    = io_u.read_h5( segmentation_filename,
                               seg_incore, seg_dset_name )#param
  dend_pairs = io_u.read_h5( segmentation_filename, true, "dend" )
  dend_values = io_u.read_h5( segmentation_filename, true, "dendValues" )
  mst_mapping = omni_u.read_MST(dend_pairs, dend_values, 0.25)

  if network_output_filename != nothing
    println("Reading semantic file...")
    #@time sem_output = io_u.read_h5( network_output_filename, sem_incore )#param
    @time sem_output = H5sBigArray(network_output_filename);
  else
    println("Initializing semantic H5Array...")
    sem_output = pinky_u.init_semantic_arr()
  end

  seg, sem_output, mst_mapping
end



function process_scan_chunk!( psd_p, inspection_block, seg_block, semmap,
  edges, locations, voxels, processed_voxels,
  psd_w, seg_w,
  scan_global_offset,
  inspection_global_offset, valid_bounds )

  #this will usually be the scan_chunk_shape, but
  # isn't likely to be so at the boundaries
  chunk_shape = size(psd_p)

  #translating the bounds of the valid data
  # to those of the inspection blocks
  ins_bounds = (valid_bounds.first  - inspection_global_offset) =>
               (valid_bounds.second - inspection_global_offset)


  for i in eachindex(psd_p)


    if !psd_p[i] continue end
    #if isnan(psd_p[i]) continue end


    isub        = ind2sub(chunk_shape,i)
    isub_global = utils.tuple_add( isub,        scan_global_offset )
    isub_ins    = utils.tuple_add( isub_global, -inspection_global_offset )


    if isub_global in processed_voxels
      pop!(processed_voxels, isub_global)
      continue
    end


    println("Processing potential synapse at index: $(isub_global)")
    offset_w = chunk_u.fill_inspection_window!( psd_w,
                              inspection_block, isub_ins,
                              w_radius, ins_bounds );
    chunk_u.fill_inspection_window!( seg_w,
                              seg_block, isub_ins,
                              w_radius, ins_bounds );

    #@assert size(psd_w) == size(seg_w)

    isub_w = utils.tuple_add( isub_ins, -offset_w )

    #debug
    #println("isub: $(isub)")
    #println("isub_seg: $(isub_seg)")
    #println("isub_global: $(isub_global)")
    #println("isub_ins: $(isub_ins)")
    #println("ins_bounds: $(ins_bounds)")
    #println("offset_w: $(offset_w)")
    #println("isub_w: $(isub_w)")
    #return

    process_synapse!( psd_w, seg_w, isub_w,
                      inspection_global_offset + offset_w,
                      semmap,
                      edges, locations, voxels, processed_voxels )
  end
end



function process_synapse!( psd_p, seg, i, offset, semmap,
  edges, locations, voxels, processed_voxels )

  syn, new_voxels = seg_u.connected_component3D( psd_p, i, cc_thresh )


  new_voxels = utils.convert_to_global_coords( new_voxels, offset )

  union!(processed_voxels, new_voxels)
  pop!(processed_voxels, utils.tuple_add(i,offset) )


  if length(new_voxels) <= size_thresh return end #param


  seg_u.dilate_by_k!( syn, dilation_param ) #param
  synapse_members, _ = utils.find_synaptic_edges( syn, seg, semmap,
                                                vol_map["axon"],
                                                vol_map["dendrite"])
  #if synapse deemed invalid (by semantic info)
  if synapse_members[1] == (0,0) return end


  #change to local coordinates?
  location = utils.coord_center_of_mass( new_voxels )

  println("Accepted synapse - adding information...")
  println(synapse_members)
  push!(locations, location)
  push!(edges, synapse_members[1])
  push!(voxels, new_voxels)

end


main( segmentation_filename, output_prefix )
#------------------------------------------

end#module end