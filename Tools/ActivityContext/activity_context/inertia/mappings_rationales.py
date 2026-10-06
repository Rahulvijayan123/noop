"""Explicit rationales for the crosswalk rows Agent C left blank (G-20d; used by ``mappings_build``).

Every entry is a one-line reason for (dataset, source label, head) -> target. ``direct (source label equals
Nara class)`` is used ONLY where the source label (or its name) is literally the Nara class name; every
other row states why the activity maps to the target. ``mappings_build.normalise`` refuses a blank
rationale that is not listed here (it never invents one).
"""

from typing import Dict, Tuple

RATIONALES: Dict[Tuple[str, str, str], str] = {
    ('hhar_watch', 'stairsup', 'locomotion'):
        "'Stair up' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('hhar_watch', 'stairsdown', 'locomotion'):
        "'Stair down' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('pamap2', '1', 'locomotion'):
        "'lying' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('pamap2', '2', 'locomotion'):
        "'sitting' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('pamap2', '3', 'posture'):
        "'standing' is standing still by protocol (upright, not ambulating), so the posture target is upright_stationary",
    ('pamap2', '3', 'locomotion'):
        "'standing' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('pamap2', '9', 'locomotion'):
        "'watching TV' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('pamap2', '12', 'locomotion'):
        "'ascending stairs' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('pamap2', '13', 'locomotion'):
        "'descending stairs' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('pamap2', '18', 'locomotion'):
        "'folding laundry' is done standing at one spot (hands busy, feet still): no sustained gait, so locomotion is stationary",
    ('mhealth', '1', 'posture'):
        "'standing still (1 min)' is standing still by protocol (upright, not ambulating), so the posture target is upright_stationary",
    ('mhealth', '1', 'locomotion'):
        "'standing still (1 min)' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('mhealth', '2', 'posture'):
        "'sitting and relaxing (1 min)' is seated by protocol, so the posture target is seated_likely",
    ('mhealth', '2', 'locomotion'):
        "'sitting and relaxing (1 min)' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('mhealth', '3', 'posture'):
        "'lying down (1 min)' is lying by protocol (awake; not a sleep-diary label), so the posture target is recumbent",
    ('mhealth', '3', 'locomotion'):
        "'lying down (1 min)' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('mhealth', '5', 'locomotion'):
        "'climbing stairs (1 min)' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('mhealth', '10', 'locomotion'):
        "'jogging (1 min)' is jogging/running gait; Nara's running class does not separate jogging from running",
    ('mhealth', '11', 'locomotion'):
        "'running (1 min)' is jogging/running gait; Nara's running class does not separate jogging from running",
    ('uci_hapt_waist', '4', 'locomotion'):
        "'SITTING' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('uci_hapt_waist', '5', 'locomotion'):
        "'STANDING' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('uci_hapt_waist', '6', 'locomotion'):
        "'LAYING' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('harth', '2', 'locomotion'):
        "direct (source label equals Nara class): label name 'running' (code 2) -> running",
    ('harth', '4', 'locomotion'):
        "'stairs (ascending)' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('harth', '5', 'locomotion'):
        "'stairs (descending)' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('harth', '6', 'posture'):
        "'standing' is standing still by protocol (upright, not ambulating), so the posture target is upright_stationary",
    ('harth', '6', 'locomotion'):
        "'standing' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('harth', '7', 'posture'):
        "'sitting' is seated by protocol, so the posture target is seated_likely",
    ('harth', '7', 'locomotion'):
        "'sitting' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('harth', '8', 'posture'):
        "'lying' is lying by protocol (awake; not a sleep-diary label), so the posture target is recumbent",
    ('harth', '8', 'locomotion'):
        "'lying' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('harth', '13', 'locomotion'):
        "'cycling (sit)' is pedalling a bicycle (seated), which is the Nara cycling class",
    ('har70plus', '4', 'locomotion'):
        "'stairs (ascending)' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('har70plus', '5', 'locomotion'):
        "'stairs (descending)' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('har70plus', '6', 'posture'):
        "'standing' is standing still by protocol (upright, not ambulating), so the posture target is upright_stationary",
    ('har70plus', '6', 'locomotion'):
        "'standing' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('har70plus', '7', 'posture'):
        "'sitting' is seated by protocol, so the posture target is seated_likely",
    ('har70plus', '7', 'locomotion'):
        "'sitting' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('har70plus', '8', 'posture'):
        "'lying' is lying by protocol (awake; not a sleep-diary label), so the posture target is recumbent",
    ('har70plus', '8', 'locomotion'):
        "'lying' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('opportunity', 'loc:4', 'posture'):
        "'Locomotion: Sit' is seated by protocol, so the posture target is seated_likely",
    ('opportunity', 'loc:4', 'locomotion'):
        "'Locomotion: Sit' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('opportunity', 'loc:5', 'locomotion'):
        "'Locomotion: Lie' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('dsads', 'A01', 'posture'):
        "'sitting' is seated by protocol, so the posture target is seated_likely",
    ('dsads', 'A01', 'locomotion'):
        "'sitting' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('dsads', 'A02', 'posture'):
        "'standing' is standing still by protocol (upright, not ambulating), so the posture target is upright_stationary",
    ('dsads', 'A02', 'locomotion'):
        "'standing' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('dsads', 'A03', 'posture'):
        "'lying on back' is lying by protocol (awake; not a sleep-diary label), so the posture target is recumbent",
    ('dsads', 'A03', 'locomotion'):
        "'lying on back' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('dsads', 'A04', 'posture'):
        "'lying on right side' is lying by protocol (awake; not a sleep-diary label), so the posture target is recumbent",
    ('dsads', 'A04', 'locomotion'):
        "'lying on right side' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('dsads', 'A05', 'locomotion'):
        "'ascending stairs' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('dsads', 'A06', 'locomotion'):
        "'descending stairs' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('dsads', 'A07', 'posture'):
        "'standing in an elevator still' is standing still (upright, not ambulating), so the posture target is upright_stationary",
    ('dsads', 'A12', 'locomotion'):
        "'running on treadmill 8 km/h': 8 km/h treadmill running is running gait (belt speed above the walk-run transition)",
    ('realworld2016', 'climbingdown', 'locomotion'):
        "'climbing stairs down' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('realworld2016', 'climbingup', 'locomotion'):
        "'climbing stairs up' is stair ambulation, which is exactly the Nara stairs class (direction is not distinguished)",
    ('realworld2016', 'running', 'locomotion'):
        "direct (source label equals Nara class): source label 'running' -> running",
    ('realworld2016', 'sitting', 'posture'):
        "'sitting' is seated by protocol, so the posture target is seated_likely",
    ('realworld2016', 'sitting', 'locomotion'):
        "'sitting' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('realworld2016', 'standing', 'posture'):
        "'standing' is standing still by protocol (upright, not ambulating), so the posture target is upright_stationary",
    ('realworld2016', 'standing', 'locomotion'):
        "'standing' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('realworld2016', 'lying', 'posture'):
        "'lying' is lying by protocol (awake; not a sleep-diary label), so the posture target is recumbent",
    ('realworld2016', 'lying', 'locomotion'):
        "'lying' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('gotov', 'standing', 'posture'):
        "'standing (rest between activities)' is standing still by protocol (upright, not ambulating), so the posture target is upright_stationary",
    ('gotov', 'standing', 'locomotion'):
        "'standing (rest between activities)' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('gotov', 'lyingDownLeft', 'posture'):
        "'lying down left' is lying by protocol (awake; not a sleep-diary label), so the posture target is recumbent",
    ('gotov', 'lyingDownLeft', 'locomotion'):
        "'lying down left' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('gotov', 'lyingDownRight', 'posture'):
        "'lying down right' is lying by protocol (awake; not a sleep-diary label), so the posture target is recumbent",
    ('gotov', 'lyingDownRight', 'locomotion'):
        "'lying down right' is lying by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('gotov', 'sittingSofa', 'posture'):
        "'sitting on sofa, watching TV' is seated by protocol, so the posture target is seated_likely",
    ('gotov', 'sittingSofa', 'locomotion'):
        "'sitting on sofa, watching TV' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('gotov', 'sittingCouch', 'locomotion'):
        "'sitting on couch, feet on couch, reading newspaper' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('gotov', 'sittingChair', 'posture'):
        "'sitting on office chair, computer work' is seated by protocol, so the posture target is seated_likely",
    ('gotov', 'sittingChair', 'locomotion'):
        "'sitting on office chair, computer work' is seated by protocol: no ambulation or vehicle travel, so locomotion is stationary",
    ('gotov', 'dishwashing', 'locomotion'):
        "'stand and wash dishes' is standing in place by protocol: no ambulation, so locomotion is stationary",
    ('gotov', 'stakingShelves', 'locomotion'):
        "'stacking shelves' mixes short steps with reaching/pushing, neither still nor sustained gait, so locomotion is other",
    ('gotov', 'vacuumCleaning', 'locomotion'):
        "'vacuum cleaning' mixes short steps with reaching/pushing, neither still nor sustained gait, so locomotion is other",
    ('gotov', 'vacuumCleaning', 'arm_behavior'):
        "'vacuum cleaning' is a sustained, repetitive push-pull arm movement, so the arm target is repetitive_hand_motion",
    ('gotov', 'cycling', 'locomotion'):
        "direct (source label equals Nara class): source label 'cycling' -> cycling",
    ('capture24', 'home activity;miscellaneous;sitting;9060 sitting/lying reading or without observable/identifiable activities;MET 1.3', 'locomotion'):
        "Compendium 9060 'sitting/lying reading or without observable/identifiable activities' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;miscellaneous;sitting;7010 sitting/lying and watching television with TV on as the primary activity;MET 1.0', 'locomotion'):
        "Compendium 7010 'sitting/lying and watching television with TV on as the primary activity' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;miscellaneous;sitting;9055 sitting/lying talking in person/using a mobile phone/smartphone/tablet or talking on the phone/computer (skype chatting);MET 1.5', 'locomotion'):
        "Compendium 9055 'sitting/lying talking in person/using a mobile phone/smartphone/tablet or talking on the phone/computer (skype chatting)' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'leisure;miscellaneous;sitting;9060 (generic) sitting/lying reading or without observable/identifiable activities;MET 1.3', 'locomotion'):
        "Compendium 9060 '(generic) sitting/lying reading or without observable/identifiable activities' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;leisure;activities for maintenance of a household;miscellaneous;9100 retreat/family reunion activities involving sitting eating relaxing talking with more than one person;MET 1.8', 'locomotion'):
        "Compendium 9100 'retreat/family reunion activities involving sitting eating relaxing talking with more than one person' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;miscellaneous;sitting;9060 sitting/lying reading or without observable activities;MET 1.3', 'locomotion'):
        "Compendium 9060 'sitting/lying reading or without observable activities' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;leisure;activties for maintenance of a household;miscellaneous;9100 retreat/family reunion activities involving sitting eating relaxing talking with more than one person;MET 1.8', 'locomotion'):
        "Compendium 9100 'retreat/family reunion activities involving sitting eating relaxing talking with more than one person' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'occupation;office and administrative support;11600 (generic) standing tasks such as store clerk/libarian/packing boxes/repair heavy parts;MET 3.0', 'locomotion'):
        "Compendium 11600 '(generic) standing tasks such as store clerk/libarian/packing boxes/repair heavy parts' is work done standing in place; occasional steps are not sustained gait or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;household chores;washing/ironing/mending clothes;5070 ironing;MET 1.8', 'locomotion'):
        'Compendium 5070 ironing is done standing in place at a board (no gait), so locomotion is stationary',
    ('capture24', 'home activity;miscellaneous;sitting;7010 lying and watching television with TV on as the primary activity;MET 1.0', 'locomotion'):
        "Compendium 7010 'lying and watching television with TV on as the primary activity' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'leisure;miscellaneous;sitting;9060 (generic) sitting/lying reading or without observable activities;MET 1.3', 'locomotion'):
        "Compendium 9060 '(generic) sitting/lying reading or without observable activities' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'occupation;office and administrative support;11600 (generic) standing tasks such as store clerk/librarian/packing boxes/repair heavy parts;MET 3.0', 'locomotion'):
        "Compendium 11600 '(generic) standing tasks such as store clerk/librarian/packing boxes/repair heavy parts' is work done standing in place; occasional steps are not sustained gait or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;leisure;activties for maintenance of a household;with children;5170 sitting playing with child(ren);MET 2.2', 'locomotion'):
        "Compendium 5170 'sitting playing with child(ren)' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;leisure;activities for maintenance of a household;with children;5170 sitting playing with child(ren);MET 2.2', 'locomotion'):
        "Compendium 5170 'sitting playing with child(ren)' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;leisure;activties for maintenance of a household;9100 retreat/family reunion activities involving sitting eating relaxing talking with more than one person;MET 1.8', 'locomotion'):
        "Compendium 9100 'retreat/family reunion activities involving sitting eating relaxing talking with more than one person' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'leisure;miscellaneous;sitting;21016 sitting child care only active periods;MET 2.0', 'locomotion'):
        "Compendium 21016 'sitting child care only active periods' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'home activity;leisure;activties for maintenance of a household;5170 sitting playing with child(ren);MET 2.2', 'locomotion'):
        "Compendium 5170 'sitting playing with child(ren)' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
    ('capture24', 'leisure;miscellaneous;21016 sitting child care only active periods;MET 2.0', 'locomotion'):
        "Compendium 21016 'sitting child care only active periods' is a sitting/lying activity with no ambulation or vehicle travel, so locomotion is stationary",
}

__all__ = ["RATIONALES"]
