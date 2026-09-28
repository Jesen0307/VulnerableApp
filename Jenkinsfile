pipeline {
    agent any

    environment {
        REPORTS_DIR = 'security-reports'
        // Jenkins container is attached to the SonarQube 'sonarnet' network,
        // so SonarQube is reachable by its Docker DNS name (stable, no hardcoded IP).
        SONAR_HOST_URL = 'http://sonarqube:9000'
        PATH = "/opt/sonar-scanner/bin:${env.PATH}"
        SONAR_TOKEN = 'squ_a76c5e818a392cb07370af0fb874c9e3fe84ec90'
        SONAR_PROJECT_KEY = 'VulnerableApp'
        SEMGREP_FAILED = 'false'
    }

    stages {
        stage('Install Dependencies') {
            steps {
                sh '''
                    sudo apt-get update
                    sudo apt-get install -y python3 python3-pip python3-venv curl unzip docker.io default-jdk

                    if [ ! -d "/usr/lib/jvm/java-17-temurin" ]; then
                        sudo mkdir -p /usr/lib/jvm/java-17-temurin
                        curl -sL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" | sudo tar -xz -C /usr/lib/jvm/java-17-temurin --strip-components=1
                    fi

                    sudo pip3 install semgrep --break-system-packages || sudo pip3 install semgrep

                    # SonarScanner CLI (pinned version; installed once on the agent)
                    SONAR_SCANNER_VERSION=8.1.0.6389
                    if [ ! -x /opt/sonar-scanner/bin/sonar-scanner ]; then
                        sudo mkdir -p /opt/sonar-scanner
                        curl -fsSL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" -o /tmp/sonar-scanner.zip
                        sudo unzip -q /tmp/sonar-scanner.zip -d /tmp/sonar-scanner-install
                        sudo cp -r /tmp/sonar-scanner-install/sonar-scanner-*/. /opt/sonar-scanner/
                        sudo chmod -R +x /opt/sonar-scanner/bin /opt/sonar-scanner/jre/bin
                        rm -rf /tmp/sonar-scanner.zip /tmp/sonar-scanner-install
                    fi
                '''
            }
        }

        stage('Build (Compile Java)') {
            steps {
                sh 'chmod +x gradlew'
                sh './gradlew classes printRuntimeClasspath --no-daemon'
            }
        }

        stage('Security Analysis') {
            steps {
                script {
                    sh 'mkdir -p $REPORTS_DIR'
                    
                    def semgrepExitCode = 0

                    parallel (
                        'Semgrep SAST': {
                            sh 'chmod +x scripts/semgrep-scan.sh'
                            // returnStatus: true captures the exit code without throwing an exception immediately
                            semgrepExitCode = sh(
                                script: './scripts/semgrep-scan.sh . $REPORTS_DIR', 
                                returnStatus: true
                            )
                        },
                        'SonarQube Analysis': {
                            sh 'chmod +x scripts/sonarqube-scan.sh'
                            sh './scripts/sonarqube-scan.sh . $SONAR_PROJECT_KEY $SONAR_HOST_URL $SONAR_TOKEN $REPORTS_DIR'
                        }
                    )

                    // Flag the failure if Semgrep detected high-severity issues (exit code non-zero)
                    if (semgrepExitCode != 0) {
                        env.SEMGREP_FAILED = 'true'
                        echo "Semgrep found blocking vulnerabilities (Exit code: ${semgrepExitCode}). Continuing pipeline for deduplication..."
                    }
                }
            }
        }

        stage('Deduplicate Findings') {
            steps {
                // This stage is guaranteed to run even if Semgrep found issues, 
                // allowing your python script to process the generated semgrep.json
                sh 'python3 scripts/security_processor.py --workspace $REPORTS_DIR'
            }
        }

        stage('Quality Gate Enforcement') {
            steps {
                script {
                    // Final gate check: Fails the build *after* your processing/deduplication logic is done
                    if (env.SEMGREP_FAILED == 'true') {
                        currentBuild.result = 'FAILURE'
                        error("Pipeline failed: Semgrep detected high-severity vulnerabilities.")
                    }
                }
            }
        }
    }

    post {
        always {
            echo 'Pipeline execution completed.'
            archiveArtifacts artifacts: "${env.REPORTS_DIR}/*.json, ${env.REPORTS_DIR}/*.log", allowEmptyArchive: true
        }
    }
}
