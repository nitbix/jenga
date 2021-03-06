
open Core.Std

include module type of Error_reason_type

val filesystem_related : t -> bool

val messages : tag:string -> t -> unit
val message_summary : Config.t -> Description.Need.t -> t -> unit
