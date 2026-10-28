# ML Kit's runtime (Firebase components) builds its registrars by reflection from manifest meta-data.
# R8 full mode keeps those classes but strips their no-arg constructors, so in release builds ML Kit
# logged "NoSuchMethodException: ...Registrar.<init>" and text recognition never initialised.
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
