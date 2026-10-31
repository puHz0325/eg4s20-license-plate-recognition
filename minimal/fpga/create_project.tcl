if {[catch {
    cd [file dirname [file normalize [info script]]]
    if {[file exists teacher_video_local.al]} {error "Preserve existing teacher_video_local.al; use the existing project or a fresh directory."}
    create_project -family EG4 -device EG4S20BG256 teacher_video_local [pwd]
    add_files -analyze video.v
    add_files video.adc
    add_files video.sdc
    import_device eagle_s20.db -package EG4S20BG256
    elaborate -top teacher_video_top
    puts "PORTABLE_PROJECT_CREATED"
} message]} {puts stderr $message;exit 1}
exit 0
