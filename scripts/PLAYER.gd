extends CharacterBody3D


#speed var
var speed 
@export_range(5,10,0.1) var CROUCH_SPEED : float = 7.0
@export var CROUCHED_SPEED = 3.0
@export var WALK_SPEED = 7.0
@export var SPRINT_SPEED = 12.0
@export var JUMP_VELOCITY = 4.5

var _is_crouching : bool = false

const sensitivity = 0.05

#fov
const fov_base = 90
const fov_change = 0.7

#bob var
const bob_frq = 2.0
const bob_amp = 0.08
var t_bob = 0.0

#references
@onready var head = $Head
@onready var cam = $Head/Camera3D
@onready var pcap = $CollisionShape3D
@onready var  anims= $AnimationPlayer
@onready var headbbonker = $HEADBONKER



# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

#camera rotation
func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	#headbonker exception is us!
	headbbonker.add_exception($".")
	
func _unhandled_input(event):
	if event is InputEventMouseMotion:
		head.rotate_x(deg_to_rad(-event.relative.y * sensitivity))
		self.rotate_y(deg_to_rad(-event.relative.x * sensitivity))
		head.rotation.x = clamp(head.rotation.x, deg_to_rad(-90), deg_to_rad(90))
		
	if Input.is_action_pressed("escape"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif Input.is_action_pressed("go_back"):
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		
	#weapon switch
	


func _physics_process(delta):
	
	#weapons

	# Add the gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Handle Jump.
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	
	#Cam bob
	t_bob= delta * velocity.length() *float(is_on_floor())
	cam.transform.origin = _headbob(t_bob)
	
	
	#speed and movement
	if Input.is_action_pressed("sprint"):
		speed=SPRINT_SPEED
	elif Input.is_action_just_pressed("crouch"):
		_toggle_crouch()
			
	else:
		speed=WALK_SPEED 
	
	var input_dir = Input.get_vector("left", "right","forward", "backward")
	var direction = (self.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	#inertia
	if is_on_floor():
		if direction:
				velocity.x = direction.x * speed
				velocity.z = direction.z * speed
		else:
				velocity.x = lerp(velocity.x, direction.x*speed, delta*6.0)
				velocity.z = lerp(velocity.z, direction.z*speed, delta*6.0)
	else:
		velocity.x = lerp(velocity.x, direction.x*speed, delta*3.0)
		velocity.z = lerp(velocity.z, direction.z*speed, delta*3.0)
		
	#fov
	var vel_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED*2 )
	var target_fov = fov_base + fov_change*vel_clamped
	cam.fov = lerp(cam.fov, target_fov, delta*8.0)

	move_and_slide()
	
func _toggle_crouch():
	
	if _is_crouching==true and headbbonker.is_colliding()==false:
		anims.play("crouch",-1,-CROUCH_SPEED,true)
		speed=WALK_SPEED
	elif _is_crouching == false:
		anims.play("crouch",-1,CROUCH_SPEED)
		speed=CROUCHED_SPEED

func _headbob(delta) -> Vector3:
		var pos= Vector3.ZERO
		pos.y = 4*sin(delta*bob_frq)*bob_amp
		pos.x = 4*cos(delta * bob_frq) *bob_amp
		return pos

func _on_animation_player_animation_started(anim_name):
	if anim_name == "crouch":
		_is_crouching=!_is_crouching
		
