extends Node3D

@export var origin: XROrigin3D # XROrigin3D node
@export var camera: XRCamera3D # ARVRCamera node
@export var controller: XRController3D
@export var physical_skeleton: Skeleton3D # physical hand skeleton node
@export var controller_skeleton: Skeleton3D # controller hand skeleton node
@export var wrist: RigidBody3D # physical hand wrist RigidBody node
@export var body: CharacterBody3D # RigidBody body node
@export var controller_hand_mesh: MeshInstance3D # controller hand Mesh Instance node
@export var finger_collider: PackedScene # finger collider node and raycasts for collision detection
@export var wrist_raycast: RayCast3D # wrist raycasts detect objects to grab
@export var wrist_joint: Generic6DOFJoint3D # joint is holding objects

var controller_hand_mesh_material
var held_object
var held_object_anchor
var wrist_acceleration
var wrist_angular_acceleration
var trigger
var physical_pivot_point: Transform3D

var state = {
	"moving": false,
	"breaking": false,
	"holding": false,
	"grabbing": false,
	"trigger": false
}

signal hold(hand, wrist)
signal reset_hand(hand)

# Variables for freezing fingers on grab collisions
var grabbing_raycasts
var freezed_poses = {}

# OpenXR specification requires 25 bones per hand
# https://registry.khronos.org/OpenXR/specs/1.0/html/xrspec.html#_conventions_of_hand_joints
var finger_bones = {
	"Wrist": [0],
	"Thumb": [1,2,3,4,5],
	"Index": [0,5,6,7,8,9],
	"Middle": [0,10,11,12,13,14],
	"Ring": [0,15,16,17,18,19],
	"Little": [0,20,21,22,23,24],
	"Palm": [25]
}
# reversed finger_bones, keys are bone_ids and values are bone names
# populated on script initialization
var finger_from_bone = {} # 0: "Wrist", 1: "Thumb", 2: "Thumb", (...)

# default rest poses will be saved here on launch
var bone_rest_poses = {}

func _ready():
	controller_hand_mesh_material = controller_hand_mesh.get_active_material(0)

	# Save rest poses and add colliders and collision detection raycasts to every bone in hand
	for bone_id in controller_skeleton.get_bone_count():
		
		# these bones are always at the end of each finger
		# they are helpers and do not need to be processed for physical hand
		if bone_id in [4, 9, 14, 19, 24]:
			pass
		
		# save current bone skeleton pose as rest pose
		bone_rest_poses[bone_id] = controller_skeleton.get_bone_global_pose(bone_id)
		# save information to which finger current bone belongs
		finger_from_bone[bone_id] = controller_skeleton.get_bone_name(bone_id).split("_")[0]
		
		# get global transform of bone
		var controller_bone_global_transform = controller_skeleton.global_transform * controller_skeleton.get_bone_global_pose(bone_id)
		
		# place physical wrist at controller wrist bone position
		if bone_id == 0:
			wrist.global_transform = controller_bone_global_transform
		
		
		# create new finger collider instance
		var collider = finger_collider.instantiate()

		# collider name is bone_id
		collider.set_name(String.num_int64(bone_id))
		
		# wrist is the driving force for physical hand and only physical object (Rigid Body)
		# that's why we add all finger colliders to it
		wrist.add_child(collider)

func _physics_process(delta):
	# calculate distance from controller wrist to physical wrist
	var distance_wrist = (controller_skeleton.global_transform * controller_skeleton.get_bone_global_pose(0)).origin - wrist.global_transform.origin
	
	# process every bone in hand
	for bone_id in controller_skeleton.get_bone_count():
		process_bones(bone_id, delta)

	if state.moving:
		# if moving key is pressed, push body to where physical hand is pointing
		# TODO: increase force when players tries to stop while moving fast in opposite direction
		body.velocity += -controller.global_transform.basis.z.normalized() * delta / 10
		
	if state.breaking:
		body.velocity += controller.global_transform.basis.z.normalized() * delta / 10
		
	# if player is trying to grab something
	if state.grabbing:
		# if raycast hit something player can grab and hold
		if wrist_raycast.get_collider():
			# if not holding, start holding
			if !state.holding:
				# get object we just grabbed
				held_object = get_node(wrist_raycast.get_collider().get_path())
				
				held_object_anchor = Node3D.new()
				held_object.add_child(held_object_anchor)
				held_object_anchor.global_transform = wrist.global_transform.translated(wrist_raycast.get_collision_point() - wrist.global_transform.origin)
				physical_pivot_point = held_object_anchor.global_transform
				
				# set joint between hand and grabbed object
				wrist_joint.set_node_a(wrist.get_path())
				wrist_joint.set_node_b(held_object.get_path())

				# reduce rotational forces to make holding more natural
				if held_object.is_class("RigidBody3D"):
					held_object.set_angular_damp(1)
					# TODO: center_of_mass when two hands are holding should be at body.physical_pivot_point
					var center_of_mass = physical_pivot_point.origin - held_object.global_transform.origin
					held_object.set_center_of_mass_mode(1) # enable custom center of mass
					held_object.set_center_of_mass(center_of_mass)
				
				# held objects are in layer 12 to filter out collisions with player head
				held_object.set_collision_layer_value(12, true)

				state.holding = true

				emit_signal("hold", self, wrist, controller_skeleton, held_object)
		
	# physical hand can be bugged or stuck and we need it to be able to reset itself automatically	
	# if physical hand is too far away from controller hand (>1m), we reset it back to controller position
	if distance_wrist.length_squared() > 1:
		reset_hand_position()	
		
func process_bones(bone_id, delta):
	var physical_bone_collider = get_node(String(wrist.get_path()) + "/" + String.num_int64(bone_id))

	# wrist (bone 0) is special as it's the driving force behind physical hand
	if bone_id == 0:		
		# reset movement from previous frame, so hand doesn't overshoot
		wrist.set_linear_velocity(Vector3.ZERO)
		wrist.set_angular_velocity(Vector3.ZERO)
		
		var controller_bone_global_transform = controller_skeleton.global_transform * controller_skeleton.get_bone_global_pose(bone_id)

		# calculate acceleration needed to reach controller position in 1 frame
		wrist_acceleration = 30 * (controller_bone_global_transform.origin - wrist.global_transform.origin) / delta
		# multiplier on angular acceleration must be reduced to 5, higher values glitch the hand
		wrist_angular_acceleration = 5 * (controller_bone_global_transform.basis * wrist.global_transform.basis.inverse()).get_euler()
		
		# apply calculated forces
		# we include body's velocity so physical hand can follow controllers when player is moving fast
		wrist.apply_central_force(wrist_acceleration + body.get_real_velocity() * 10)
		wrist.apply_torque(wrist_angular_acceleration)
		
		# show controller ghost hand when it's far from physical hand
		var distance_wrist = (controller_skeleton.global_transform * controller_skeleton.get_bone_global_pose(0)).origin - wrist.global_transform.origin
		var distance_alpha = clamp((distance_wrist.length() - 0.1), 0, 0.5)
		var color = controller_hand_mesh_material.get_albedo()
		color.a = distance_alpha
		controller_hand_mesh_material.set_albedo(color)
#	END WRIST PROCESSING
		
	# every physical bone collider needs to follow its bone relative to RigidBody wrist position
	# translation to Z=0.01 is needed because collider needs to begin with bone, not in the middle
	# if we do translation, it messes up with physical mesh so we revert it for physical hand mesh
	var physical_bone_target_transform = (controller_skeleton.get_bone_global_pose(0).inverse() * controller_skeleton.get_bone_global_pose(bone_id)).translated(Vector3(0, 0, 0.01)).rotated_local(Vector3.LEFT, deg_to_rad(-90))
	
	# we add short lag to physical collider following controller bones, so raycasts can detect collisions
	# TODO: Controller fingers do not follow natural path like real ones, but instead OpenXR runtime only sends current fingers location frame by frame
		# if player presses grab button quickly, fingers teleport from rest pose to full grab pose in 1 frame, resulting in raycasts not detecting any collisions during grab
		# it causes fingers going through held object instead of stopping on its surface
		# potential solution described in this GDC talk at 12:50 mark: https://www.gdcvault.com/play/1024240/It-s-All-in-the
	physical_bone_collider.transform = physical_bone_collider.transform.interpolate_with(physical_bone_target_transform, 0.4)

	# physical skeleton follows Wrist RigidBody and copies controller bones
	if bone_id == 0:
		physical_skeleton.set_bone_pose_position(bone_id, wrist.global_transform.origin)
		physical_skeleton.set_bone_pose_rotation(bone_id, Quaternion(wrist.global_transform.basis))
	else:
		physical_skeleton.set_bone_pose_position(bone_id, controller_skeleton.get_bone_pose_position(bone_id))
		physical_skeleton.set_bone_pose_rotation(bone_id, controller_skeleton.get_bone_pose_rotation(bone_id))
	
	# freezing fingers around grabbed objects
	var bone_raycasts = physical_bone_collider.get_node("RayCasts").get_children()
	# for every raycast in physical bone
	for raycast in bone_raycasts:
		# check if any of them is detecting collision
		raycast.force_raycast_update()
		if raycast.get_collider():
			# if yes, we will freeze this bone and backward bones
			# first, we check which finger this bone belongs to
			var finger = finger_from_bone[bone_id]
		
			# we iterate through every bone in this finger
			for finger_bone in finger_bones[finger]:
				# only process bones which are backwards from colliding bone (or the colliding bone itself)
				if finger_bone <= bone_id:
					# check if we already have frozen pose for this bone
					if !freezed_poses.has(finger_bone):
						# if not, save current bone pose to freezed poses
						freezed_poses[finger_bone] = controller_skeleton.get_bone_global_pose(finger_bone)

					# if player is grabbing, only then we freeze fingers on previously detected collision points
					if state.grabbing:	
						# apply freezed pose to current bone
						controller_skeleton.set_bone_global_pose_override(finger_bone, freezed_poses[finger_bone], 1.0, true)
			
			# if one raycast is detecting collision already, we don't need to check others
			break

func unfreeze_bones():
	controller_skeleton.clear_bones_global_pose_override()
	freezed_poses.clear()


# drop held object and move physical hand back to controller position
func reset_hand_position():
	state.grabbing = false
	state.holding = false
	
	if held_object:
		wrist_joint.set_node_a("")
		wrist_joint.set_node_b("")
		
		if held_object.is_class("RigidBody3D"):
			held_object.set_angular_damp(0)
			held_object.set_center_of_mass_mode(0)
		held_object.set_collision_layer_value(12, false)
		held_object = null
		held_object_anchor.queue_free()
		
	wrist.global_transform.origin = (controller_skeleton.global_transform * controller_skeleton.get_bone_global_pose(0)).origin
	
	unfreeze_bones()
	
	emit_signal("reset_hand", self)
	


func _on_xr_controller_3d_button_pressed(name):
	if name == "grip_click":
		state.grabbing = true
		
	if name == "by_button":
		state.moving = true
		
	if name == "ax_button":
		state.breaking = true
		
	if name == "trigger_click":
		trigger = true


func _on_xr_controller_3d_button_released(name):
	if name == "grip_click":
		state.grabbing = false
		reset_hand_position()
		
	if name == "by_button":
		state.moving = false
		
	if name == "ax_button":
		state.breaking = false
		
	if name == "trigger_click":
		trigger = false


func _on_hand_pose_recognition_new_pose(pose, previouse_pose):
	if pose in ["half_grip", "full_grip", "thumb_up", "point"]:
		state.grabbing = true
	
	if pose in ["open", "rest"]:
		state.grabbing = false
